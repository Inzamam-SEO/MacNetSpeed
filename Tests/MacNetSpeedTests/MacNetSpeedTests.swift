import XCTest
@testable import MacNetSpeed

final class MacNetSpeedTests: XCTestCase {
    private let posix = Locale(identifier: "en_US_POSIX")

    func testByteTotalsMatchActivityMonitorUnits() {
        XCTAssertEqual(NetworkFormat.bytes(73_600_000_000, locale: posix), "73.60 GB")
        XCTAssertEqual(NetworkFormat.bytes(21_160_000_000, locale: posix), "21.16 GB")
        XCTAssertEqual(NetworkFormat.bytes(0, locale: posix), "0 bytes")
        XCTAssertEqual(NetworkFormat.bytes(842, locale: posix), "842 bytes")
    }

    func testSpeedsUseDecimalBytesPerSecond() {
        XCTAssertEqual(NetworkFormat.speed(2_110_000, locale: posix), "2.11 MB/s")
        XCTAssertEqual(NetworkFormat.speed(1_310_000, locale: posix), "1.31 MB/s")
        XCTAssertEqual(NetworkFormat.speed(49_110, locale: posix), "49.11 KB/s")
        XCTAssertEqual(NetworkFormat.speed(0, locale: posix), "0 B/s")
    }

    func testAllInterfacesSkipLoopback() {
        let interfaces = [
            InterfaceCounters(name: "lo0", isLoopback: true, bytesIn: 9_000, bytesOut: 9_000, packetsIn: 10, packetsOut: 10),
            InterfaceCounters(name: "en0", isLoopback: false, bytesIn: 500, bytesOut: 200, packetsIn: 4, packetsOut: 3),
            InterfaceCounters(name: "utun0", isLoopback: false, bytesIn: 50, bytesOut: 20, packetsIn: 1, packetsOut: 1),
        ]
        let totals = NetworkCounters.totals(from: interfaces, selection: NetworkCounters.allInterfaces)
        XCTAssertEqual(totals.bytesIn, 550)
        XCTAssertEqual(totals.bytesOut, 220)
        XCTAssertEqual(totals.packetsIn, 5)
        XCTAssertEqual(totals.packetsOut, 4)

        let wifi = NetworkCounters.totals(from: interfaces, selection: "en0")
        XCTAssertEqual(wifi.bytesIn, 500)
        XCTAssertEqual(wifi.bytesOut, 200)
    }

    func testHelperProcessesGroupUnderTheApp() {
        XCTAssertEqual(AppTrafficName.displayName(from: "Google Chrome Helper"), "Google Chrome")
        XCTAssertEqual(AppTrafficName.displayName(from: "Google Chrome Helper (Renderer)"), "Google Chrome")
        XCTAssertEqual(AppTrafficName.displayName(from: "Safari"), "Safari")
    }

    func testCounterResetDoesNotSpike() {
        XCTAssertEqual(NetworkCounters.delta(current: 150, previous: 100), 50)
        XCTAssertEqual(NetworkCounters.delta(current: 10, previous: 4_000_000_000), 0)
    }

    func testLiveCountersExposeLoopbackAndAPhysicalInterface() {
        let interfaces = NetworkCounters.interfaces()
        XCTAssertFalse(interfaces.isEmpty)
        XCTAssertTrue(interfaces.contains { $0.isLoopback && $0.name == "lo0" })
        XCTAssertTrue(interfaces.contains { !$0.isLoopback })
    }

    func testWiFiCountersUse64BitTotalsWhenActive() throws {
        guard let en0 = NetworkCounters.interfaces().first(where: { $0.name == "en0" }) else {
            throw XCTSkip("No Wi-Fi interface on this machine.")
        }
        guard en0.packetsIn > 1_000_000 else {
            throw XCTSkip("Wi-Fi counters are too fresh to validate 64-bit totals.")
        }
        XCTAssertGreaterThan(
            en0.bytesIn,
            4_000_000_000,
            "Byte totals must use the kernel's 64-bit counters, not a truncated value."
        )
    }
}
