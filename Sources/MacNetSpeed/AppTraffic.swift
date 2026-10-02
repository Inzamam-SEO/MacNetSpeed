import Darwin
import Foundation
import ObjectiveC

final class AppTrafficSink: @unchecked Sendable {
    var handler: (@Sendable ([AppTraffic]) -> Void)?
}

struct AppTraffic: Identifiable, Equatable, Sendable {
    var name: String
    var bytesIn: UInt64
    var bytesOut: UInt64
    var downloadPerSecond: Double
    var uploadPerSecond: Double

    var id: String { name }
    var totalBytes: UInt64 { bytesIn &+ bytesOut }
}

enum AppTrafficName {
    /// Groups helper processes under the app the user recognizes.
    /// "Google Chrome Helper (Renderer)" becomes "Google Chrome".
    static func displayName(from processName: String) -> String {
        let trimmed = processName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: " Helper") else { return trimmed }
        let base = trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? trimmed : String(base)
    }
}

/// Reads live TCP and UDP flows only while the Top Apps list is open.
/// The menu-bar speeds keep using the cheap interface counters and never wait on this.
final class AppTrafficEngine: NSObject, @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "com.macnetspeed.flows.state", qos: .utility)
    private let callbackQueue = DispatchQueue(label: "com.macnetspeed.flows.callbacks", qos: .utility)
    private let onUpdate: @Sendable ([AppTraffic]) -> Void
    private struct FlowRecord {
        var name = ""
        var received: UInt64 = 0
        var sent: UInt64 = 0
    }

    private var manager: AnyObject?
    private var sources: [ObjectIdentifier: AnyObject] = [:]
    private var flows: [ObjectIdentifier: FlowRecord] = [:]
    private var previousFlowBytes: [ObjectIdentifier: (UInt64, UInt64)] = [:]
    private var closedBytes: [String: (UInt64, UInt64)] = [:]
    private var previousInstant: ContinuousClock.Instant?
    private var lastPublished: [AppTraffic] = []
    private var unknownCursor = 0
    private var knownCursor = 0
    private var timer: DispatchSourceTimer?
    private var running = false
    private var warmingUp = false
    private var warmupTicks = 0

    init(onUpdate: @escaping @Sendable ([AppTraffic]) -> Void) {
        self.onUpdate = onUpdate
        super.init()
    }

    func start() {
        stateQueue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        stateQueue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    private func startOnQueue() {
        guard !running else { return }
        guard dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics", RTLD_LAZY) != nil,
              let managerClass: AnyClass = NSClassFromString("NWStatisticsManager")
        else {
            onUpdate([])
            return
        }

        let allocated = ObjCMessage.returningObject(managerClass, "alloc")
        guard let created = ObjCMessage.returningObject(allocated, "initWithQueue:", queue: callbackQueue) else {
            onUpdate([])
            return
        }
        ObjCMessage.perform(created, "setDelegate:", object: self)
        ObjCMessage.perform(created, "addAllTCP:", bool: false)
        ObjCMessage.perform(created, "addAllUDP:", bool: false)
        self.manager = created
        running = true
        warmingUp = true

        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        // Short ticks spread the first look across many connections so the click stays responsive.
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(250), leeway: .milliseconds(40))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    private func stopOnQueue() {
        running = false
        warmingUp = false
        timer?.cancel()
        timer = nil
        if let manager {
            ObjCMessage.perform(manager, "setDelegate:", object: nil)
            ObjCMessage.perform(manager, "invalidate")
        }
        manager = nil
        sources.removeAll()
        flows.removeAll()
        previousFlowBytes.removeAll()
        closedBytes.removeAll()
        previousInstant = nil
        lastPublished = []
        unknownCursor = 0
        knownCursor = 0
        warmupTicks = 0
    }

    @objc(statisticsManager:didAddSource:)
    func statisticsManager(_ manager: AnyObject, didAddSource source: AnyObject) {
        // Keep this callback cheap. Counting every connection here is what stalled the click.
        ObjCMessage.perform(source, "setDelegate:", object: self)
        let identifier = ObjectIdentifier(source)
        stateQueue.async { [weak self] in
            guard let self, self.running else { return }
            guard self.sources.count < 5_000 || self.sources[identifier] != nil else { return }
            self.sources[identifier] = source
        }
    }

    @objc(sourceDidReceiveDescription:)
    func sourceDidReceiveDescription(_ source: AnyObject) {
        stateQueue.async { [weak self] in
            guard let self, self.running else { return }
            self.remember(source)
        }
    }

    @objc(sourceDidReceiveCounts:)
    func sourceDidReceiveCounts(_ source: AnyObject) {
        stateQueue.async { [weak self] in
            guard let self, self.running else { return }
            self.remember(source)
        }
    }

    @objc(statisticsManager:didRemoveSource:)
    func statisticsManager(_ manager: AnyObject, didRemoveSource source: AnyObject) {
        let identifier = ObjectIdentifier(source)
        stateQueue.async { [weak self] in
            guard let self, self.running else { return }
            if let record = self.flows[identifier] {
                let name = AppTrafficName.displayName(from: record.name)
                if !name.isEmpty, record.received > 0 || record.sent > 0 {
                    let existing = self.closedBytes[name] ?? (0, 0)
                    self.closedBytes[name] = (existing.0 &+ record.received, existing.1 &+ record.sent)
                }
            }
            self.sources.removeValue(forKey: identifier)
            self.flows.removeValue(forKey: identifier)
            self.previousFlowBytes.removeValue(forKey: identifier)
        }
    }

    private func remember(_ source: AnyObject) {
        guard running, flows.count < 5_000 || flows[ObjectIdentifier(source)] != nil else { return }
        guard let snapshot = ObjCMessage.returningObject(source, "currentSnapshot") else { return }
        var record = flows[ObjectIdentifier(source)] ?? FlowRecord()
        record.received = ObjCMessage.unsigned(snapshot, "rxBytes")
        record.sent = ObjCMessage.unsigned(snapshot, "txBytes")
        if let name = ObjCMessage.returningObject(snapshot, "processName") as? String, !name.isEmpty {
            record.name = name
        }
        flows[ObjectIdentifier(source)] = record
    }

    private func tick() {
        guard running else { return }
        let unknownLeft = refreshConnections()
        publish()
        guard warmingUp else { return }
        warmupTicks += 1
        guard unknownLeft == 0 || warmupTicks >= 8 else { return }
        warmingUp = false
        timer?.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2), leeway: .milliseconds(250))
    }

    /// Asks a small batch of connections for their counts. Returns how many are still unseen.
    private func refreshConnections() -> Int {
        var unknown: [ObjectIdentifier] = []
        var known: [ObjectIdentifier] = []
        unknown.reserveCapacity(sources.count)
        for identifier in sources.keys {
            let record = flows[identifier] ?? FlowRecord()
            if record.name.isEmpty && record.received == 0 && record.sent == 0 {
                unknown.append(identifier)
            } else {
                known.append(identifier)
            }
        }

        let budget = warmingUp ? 36 : 48
        let unknownBudget = min(unknown.count, warmingUp ? budget : min(12, budget))
        query(unknown, count: unknownBudget, cursor: &unknownCursor, includeDescription: true)
        let knownBudget = min(known.count, max(0, budget - unknownBudget))
        query(known, count: knownBudget, cursor: &knownCursor, includeDescription: false)
        return unknown.count - unknownBudget
    }

    private func query(
        _ identifiers: [ObjectIdentifier],
        count: Int,
        cursor: inout Int,
        includeDescription: Bool
    ) {
        guard count > 0, !identifiers.isEmpty else { return }
        let start = cursor % identifiers.count
        for offset in 0..<count {
            guard running else { return }
            let identifier = identifiers[(start + offset) % identifiers.count]
            guard let source = sources[identifier] else { continue }
            if includeDescription {
                ObjCMessage.perform(source, "queryDescription")
            }
            ObjCMessage.perform(source, "queryCounts")
        }
        cursor = start + count
    }

    private func publish() {
        guard running else { return }
        let now = ContinuousClock.now
        var totals: [String: (UInt64, UInt64)] = closedBytes
        var intervalBytes: [String: (UInt64, UInt64)] = [:]
        for (identifier, record) in flows {
            guard record.received > 0 || record.sent > 0 else { continue }
            let name = AppTrafficName.displayName(from: record.name)
            guard !name.isEmpty else { continue }
            let existing = totals[name] ?? (0, 0)
            totals[name] = (existing.0 &+ record.received, existing.1 &+ record.sent)
            if let previous = previousFlowBytes[identifier] {
                let down = NetworkCounters.delta(current: record.received, previous: previous.0)
                let up = NetworkCounters.delta(current: record.sent, previous: previous.1)
                let soFar = intervalBytes[name] ?? (0, 0)
                intervalBytes[name] = (soFar.0 &+ down, soFar.1 &+ up)
            }
            previousFlowBytes[identifier] = (record.received, record.sent)
        }

        let elapsed = previousInstant.map { seconds(from: $0.duration(to: now)) }
        let rows = totals.map { name, bytes -> AppTraffic in
            var down = 0.0
            var up = 0.0
            if let elapsed, elapsed >= 0.4, elapsed <= 6, let interval = intervalBytes[name] {
                down = Double(interval.0) / elapsed
                up = Double(interval.1) / elapsed
            }
            return AppTraffic(
                name: name,
                bytesIn: bytes.0,
                bytesOut: bytes.1,
                downloadPerSecond: down,
                uploadPerSecond: up
            )
        }
        .filter { $0.totalBytes > 0 }
        .sorted { lhs, rhs in
            let leftRate = lhs.downloadPerSecond + lhs.uploadPerSecond
            let rightRate = rhs.downloadPerSecond + rhs.uploadPerSecond
            if leftRate != rightRate { return leftRate > rightRate }
            return lhs.totalBytes > rhs.totalBytes
        }

        let top = Array(rows.prefix(20))
        previousInstant = now
        guard top != lastPublished else { return }
        if top.isEmpty, warmingUp { return }
        lastPublished = top
        onUpdate(top)
    }

    private func seconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

}

enum AppTrafficDump {
    static func run() {
        let engine = AppTrafficEngine { apps in
            print("apps \(apps.count)")
            for app in apps.prefix(8) {
                print("  \(app.name) ↓\(Int(app.downloadPerSecond)) ↑\(Int(app.uploadPerSecond)) in=\(app.bytesIn) out=\(app.bytesOut)")
            }
            fflush(stdout)
        }
        engine.start()
        Thread.sleep(forTimeInterval: 3.2)
        engine.stop()
        Thread.sleep(forTimeInterval: 0.2)
    }
}

private enum ObjCMessage {
    private nonisolated(unsafe) static let raw: UnsafeMutableRawPointer = {
        guard let handle = dlopen("/usr/lib/libobjc.A.dylib", RTLD_NOW),
              let symbol = dlsym(handle, "objc_msgSend")
        else {
            fatalError("objc_msgSend is unavailable")
        }
        return symbol
    }()

    static func perform(_ object: AnyObject, _ name: String) {
        let function = unsafeBitCast(raw, to: (@convention(c) (AnyObject, Selector) -> Void).self)
        function(object, sel_getUid(name))
    }

    static func perform(_ object: AnyObject, _ name: String, object argument: AnyObject?) {
        let function = unsafeBitCast(raw, to: (@convention(c) (AnyObject, Selector, AnyObject?) -> Void).self)
        function(object, sel_getUid(name), argument)
    }

    static func perform(_ object: AnyObject, _ name: String, bool argument: Bool) {
        let function = unsafeBitCast(raw, to: (@convention(c) (AnyObject, Selector, Bool) -> Void).self)
        function(object, sel_getUid(name), argument)
    }

    static func returningObject(_ object: AnyClass, _ name: String) -> AnyObject {
        let function = unsafeBitCast(raw, to: (@convention(c) (AnyClass, Selector) -> AnyObject).self)
        return function(object, sel_getUid(name))
    }

    static func returningObject(_ object: AnyObject, _ name: String) -> AnyObject? {
        let function = unsafeBitCast(raw, to: (@convention(c) (AnyObject, Selector) -> AnyObject?).self)
        return function(object, sel_getUid(name))
    }

    static func returningObject(_ object: AnyObject, _ name: String, queue: DispatchQueue) -> AnyObject? {
        let function = unsafeBitCast(raw, to: (@convention(c) (AnyObject, Selector, DispatchQueue) -> AnyObject?).self)
        return function(object, sel_getUid(name), queue)
    }

    static func unsigned(_ object: AnyObject, _ name: String) -> UInt64 {
        let function = unsafeBitCast(raw, to: (@convention(c) (AnyObject, Selector) -> UInt64).self)
        return function(object, sel_getUid(name))
    }
}
