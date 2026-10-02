import Foundation
import Observation

struct RateSample: Sendable, Equatable {
    var bytesDown: Double
    var bytesUp: Double
    var packetsDown: Double
    var packetsUp: Double
}

struct InterfaceChoice: Identifiable, Equatable {
    var id: String
    var title: String
}

@MainActor
@Observable
final class NetworkMonitor {
    static let historyLength = 60

    private(set) var bytesIn: UInt64 = 0
    private(set) var bytesOut: UInt64 = 0
    private(set) var packetsIn: UInt64 = 0
    private(set) var packetsOut: UInt64 = 0
    private(set) var downloadBytesPerSecond: Double = 0
    private(set) var uploadBytesPerSecond: Double = 0
    private(set) var downloadPacketsPerSecond: Double = 0
    private(set) var uploadPacketsPerSecond: Double = 0
    private(set) var samples: [RateSample] = []
    private(set) var interfaces: [InterfaceChoice] = []
    private(set) var appTraffic: [AppTraffic] = []
    private(set) var appsReady = false

    /// Opens the per-app list. Flow accounting starts only while this is on,
    /// and only after this click has finished drawing.
    var showApps = false {
        didSet {
            guard showApps != oldValue, allowsAppEngine else { return }
            scheduleAppEngine()
        }
    }

    private let appEngine: AppTrafficEngine
    private var allowsAppEngine = true
    private var appEngineTicket = 0

    var interfaceID: String {
        didSet {
            guard interfaceID != oldValue else { return }
            UserDefaults.standard.set(interfaceID, forKey: Keys.interface)
            resetRates()
        }
    }

    var graphMode: GraphMode {
        didSet {
            UserDefaults.standard.set(graphMode.rawValue, forKey: Keys.graphMode)
        }
    }

    /// Sample interval. Activity Monitor's View → Update Frequency uses 1, 2, or 5 seconds.
    var interval: TimeInterval {
        didSet {
            let clamped = min(5, max(1, interval))
            if clamped != interval { interval = clamped; return }
            UserDefaults.standard.set(interval, forKey: Keys.interval)
            resetRates()
        }
    }

    private var loop: Task<Void, Never>?
    private var previous: TrafficTotals?
    private var previousInstant: ContinuousClock.Instant?

    init() {
        let defaults = UserDefaults.standard
        interfaceID = defaults.string(forKey: Keys.interface) ?? NetworkCounters.allInterfaces
        graphMode = GraphMode(rawValue: defaults.string(forKey: Keys.graphMode) ?? "") ?? .data
        let storedInterval = defaults.object(forKey: Keys.interval) as? Double ?? 1
        interval = min(5, max(1, storedInterval))
        let sink = AppTrafficSink()
        appEngine = AppTrafficEngine { apps in
            sink.handler?(apps)
        }
        sink.handler = { [weak self] apps in
            Task { @MainActor in
                guard let self, self.showApps else { return }
                self.appTraffic = apps
                self.appsReady = true
            }
        }
    }

    /// Lets the disclosure finish opening or closing before flow accounting starts or stops.
    private func scheduleAppEngine() {
        appEngineTicket += 1
        let ticket = appEngineTicket
        let shouldRun = showApps
        DispatchQueue.main.async { [weak self] in
            guard let self, self.appEngineTicket == ticket else { return }
            if shouldRun {
                self.appEngine.start()
            } else {
                self.appEngine.stop()
                self.appTraffic = []
                self.appsReady = false
            }
        }
    }

    func installPreviewFixture() {
        allowsAppEngine = false
        bytesIn = 73_600_000_000
        bytesOut = 21_160_000_000
        packetsIn = 1_234_567
        packetsOut = 890_123
        downloadBytesPerSecond = 2_110_000
        uploadBytesPerSecond = 1_310_000
        downloadPacketsPerSecond = 420
        uploadPacketsPerSecond = 180
        interfaceID = NetworkCounters.allInterfaces
        samples = (0..<NetworkMonitor.historyLength).map { index in
            let t = Double(index)
            let spike = exp(-pow((t - 42) / 2.4, 2))
            let quiet = 0.04 + 0.03 * sin(t / 4)
            return RateSample(
                bytesDown: (quiet + spike) * 2_110_000,
                bytesUp: (quiet * 0.6 + spike * 0.62) * 1_310_000,
                packetsDown: spike * 400,
                packetsUp: spike * 180
            )
        }
        interfaces = [InterfaceChoice(id: "en0", title: "Wi-Fi (en0)")]
    }

    func installPreviewApps() {
        allowsAppEngine = false
        appTraffic = [
            AppTraffic(name: "Google Chrome", bytesIn: 21_350_608, bytesOut: 17_751_062, downloadPerSecond: 266_890, uploadPerSecond: 180_200),
            AppTraffic(name: "Cursor", bytesIn: 4_372_000, bytesOut: 2_432_000, downloadPerSecond: 48_200, uploadPerSecond: 12_400),
            AppTraffic(name: "Mail", bytesIn: 903_750, bytesOut: 138_850, downloadPerSecond: 1_200, uploadPerSecond: 400),
            AppTraffic(name: "Safari", bytesIn: 512_000, bytesOut: 88_000, downloadPerSecond: 0, uploadPerSecond: 0),
        ]
        appsReady = true
        showApps = true
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        let clock = ContinuousClock()
        while !Task.isCancelled {
            let started = clock.now
            let snapshot = await Task.detached(priority: .utility) {
                NetworkCounters.snapshot()
            }.value
            apply(snapshot, at: clock.now)
            let elapsed = clock.now - started
            let remaining = Duration.seconds(interval) - elapsed
            if remaining > .zero {
                try? await Task.sleep(for: remaining)
            }
        }
    }

    private func apply(_ snapshot: NetworkSnapshot, at now: ContinuousClock.Instant) {
        interfaces = choices(from: snapshot)
        let totals = NetworkCounters.totals(from: snapshot.interfaces, selection: interfaceID)
        bytesIn = totals.bytesIn
        bytesOut = totals.bytesOut
        packetsIn = totals.packetsIn
        packetsOut = totals.packetsOut

        guard let previous, let previousInstant else {
            self.previous = totals
            self.previousInstant = now
            return
        }

        let dt = seconds(from: previousInstant.duration(to: now))
        self.previous = totals
        self.previousInstant = now

        // A late sample after sleep or a stall would smear the whole gap into one
        // point and draw a spike Activity Monitor never shows. Drop that sample.
        guard dt >= interval * 0.5, dt <= interval * 2.5 else {
            downloadBytesPerSecond = 0
            uploadBytesPerSecond = 0
            downloadPacketsPerSecond = 0
            uploadPacketsPerSecond = 0
            append(RateSample(bytesDown: 0, bytesUp: 0, packetsDown: 0, packetsUp: 0))
            return
        }

        let bytesDown = Double(NetworkCounters.delta(current: totals.bytesIn, previous: previous.bytesIn)) / dt
        let bytesUp = Double(NetworkCounters.delta(current: totals.bytesOut, previous: previous.bytesOut)) / dt
        let packetsDown = Double(NetworkCounters.delta(current: totals.packetsIn, previous: previous.packetsIn)) / dt
        let packetsUp = Double(NetworkCounters.delta(current: totals.packetsOut, previous: previous.packetsOut)) / dt

        downloadBytesPerSecond = bytesDown
        uploadBytesPerSecond = bytesUp
        downloadPacketsPerSecond = packetsDown
        uploadPacketsPerSecond = packetsUp
        append(
            RateSample(
                bytesDown: bytesDown,
                bytesUp: bytesUp,
                packetsDown: packetsDown,
                packetsUp: packetsUp
            )
        )
    }

    private func append(_ sample: RateSample) {
        samples.append(sample)
        if samples.count > Self.historyLength {
            samples.removeFirst(samples.count - Self.historyLength)
        }
    }

    private func resetRates() {
        previous = nil
        previousInstant = nil
        samples.removeAll()
        downloadBytesPerSecond = 0
        uploadBytesPerSecond = 0
        downloadPacketsPerSecond = 0
        uploadPacketsPerSecond = 0
    }

    private func choices(from snapshot: NetworkSnapshot) -> [InterfaceChoice] {
        snapshot.interfaces
            .filter { interface in
                guard !interface.isLoopback else { return false }
                let seenTraffic = interface.bytesIn > 0 || interface.bytesOut > 0
                return seenTraffic || interface.name == "en0" || interface.name == interfaceID
            }
            .sorted { lhs, rhs in
                let leftPhysical = lhs.name.hasPrefix("en")
                let rightPhysical = rhs.name.hasPrefix("en")
                if leftPhysical != rightPhysical { return leftPhysical }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .map { interface in
                let friendly = snapshot.displayNames[interface.name] ?? interface.name
                let title = friendly == interface.name ? interface.name : "\(friendly) (\(interface.name))"
                return InterfaceChoice(id: interface.name, title: title)
            }
    }

    private func seconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    var selectedInterfaceTitle: String {
        if interfaceID == NetworkCounters.allInterfaces {
            return "All interfaces"
        }
        return interfaces.first { $0.id == interfaceID }?.title ?? interfaceID
    }

    private enum Keys {
        static let interface = "interfaceID"
        static let graphMode = "graphMode"
        static let interval = "sampleInterval"
    }
}
