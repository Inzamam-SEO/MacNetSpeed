import Darwin
import Foundation
import SystemConfiguration

/// One interface's counters from the kernel's 64-bit link totals.
/// Activity Monitor and `netstat -ib` read these same values.
struct InterfaceCounters: Sendable, Equatable, Identifiable {
    var name: String
    var isLoopback: Bool
    var bytesIn: UInt64
    var bytesOut: UInt64
    var packetsIn: UInt64
    var packetsOut: UInt64

    var id: String { name }
}

struct TrafficTotals: Sendable, Equatable {
    var bytesIn: UInt64
    var bytesOut: UInt64
    var packetsIn: UInt64
    var packetsOut: UInt64

    static let zero = TrafficTotals(bytesIn: 0, bytesOut: 0, packetsIn: 0, packetsOut: 0)
}

struct NetworkSnapshot: Sendable {
    var interfaces: [InterfaceCounters]
    var displayNames: [String: String]
}

enum NetworkCounters {
    /// `all` matches Activity Monitor: every interface except loopback.
    static let allInterfaces = "all"

    static func snapshot() -> NetworkSnapshot {
        NetworkSnapshot(interfaces: interfaces(), displayNames: displayNamesByBSD())
    }

    static func interfaces() -> [InterfaceCounters] {
        if let netstat = NetstatInterfaces.read(), !netstat.isEmpty {
            return netstat
        }
        return RouteSocketInterfaces.read()
    }

    static func totals(from interfaces: [InterfaceCounters], selection: String) -> TrafficTotals {
        let included = interfaces.filter { interface in
            guard !interface.isLoopback else { return false }
            if selection == allInterfaces { return true }
            return interface.name == selection
        }
        return included.reduce(into: TrafficTotals.zero) { totals, interface in
            totals.bytesIn += interface.bytesIn
            totals.bytesOut += interface.bytesOut
            totals.packetsIn += interface.packetsIn
            totals.packetsOut += interface.packetsOut
        }
    }

    /// A backwards counter means the interface was recreated. Reporting that as
    /// traffic produces a multi-gigabyte spike, so the sample is dropped.
    static func delta(current: UInt64, previous: UInt64) -> UInt64 {
        guard current >= previous else { return 0 }
        return current - previous
    }

    static func displayNamesByBSD() -> [String: String] {
        let array = SCNetworkInterfaceCopyAll() as NSArray
        var names: [String: String] = [:]
        for case let interface as SCNetworkInterface in array {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            let localized = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
            if let localized, !localized.isEmpty {
                names[bsd] = localized
            }
        }
        return names
    }
}

/// Same 64-bit totals Activity Monitor shows. On recent macOS releases the route
/// socket snapshot can truncate `ifi_ibytes`, so we read `netstat -ibn` instead.
private enum NetstatInterfaces {
    static func read() -> [InterfaceCounters]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-ibn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var result: [InterfaceCounters] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 10 else { continue }
            guard fields[2].hasPrefix("<Link#") else { continue }
            let name = fields[0]
            guard let packetsIn = UInt64(fields[4]),
                  let bytesIn = UInt64(fields[6]),
                  let packetsOut = UInt64(fields[7]),
                  let bytesOut = UInt64(fields[9])
            else { continue }
            result.append(
                InterfaceCounters(
                    name: name,
                    isLoopback: name == "lo0",
                    bytesIn: bytesIn,
                    bytesOut: bytesOut,
                    packetsIn: packetsIn,
                    packetsOut: packetsOut
                )
            )
        }
        return result.isEmpty ? nil : result
    }
}

/// Fallback when `netstat` is unavailable. Totals may be wrong on some macOS versions.
private enum RouteSocketInterfaces {
    static func read() -> [InterfaceCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard Darwin.sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: length)
        let copied = buffer.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.sysctl(&mib, 6, base, &length, nil, 0)
        }
        guard copied == 0 else { return [] }

        return buffer.withUnsafeBytes { raw -> [InterfaceCounters] in
            var result: [InterfaceCounters] = []
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= raw.count {
                let messageLength = Int(raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self).ifm_msglen)
                if messageLength <= 0 { break }

                let type = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self).ifm_type
                if type == UInt8(RTM_IFINFO2), offset + MemoryLayout<if_msghdr2>.size <= raw.count {
                    let index = raw.loadUnaligned(fromByteOffset: offset + Layout.indexOffset, as: UInt16.self)
                    let flags = raw.loadUnaligned(fromByteOffset: offset + Layout.flagsOffset, as: Int32.self)
                    let dataBase = offset + Layout.dataOffset
                    let bytesIn = readUInt64(raw, dataBase + Layout.bytesInOffset)
                    let bytesOut = readUInt64(raw, dataBase + Layout.bytesOutOffset)
                    let packetsIn = readUInt64(raw, dataBase + Layout.packetsInOffset)
                    let packetsOut = readUInt64(raw, dataBase + Layout.packetsOutOffset)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(index), &nameBuffer) != nil {
                        let name = nameBuffer.withUnsafeBufferPointer { pointer -> String in
                            guard let base = pointer.baseAddress else { return "" }
                            return String(cString: base)
                        }
                        result.append(
                            InterfaceCounters(
                                name: name,
                                isLoopback: (flags & IFF_LOOPBACK) != 0,
                                bytesIn: bytesIn,
                                bytesOut: bytesOut,
                                packetsIn: packetsIn,
                                packetsOut: packetsOut
                            )
                        )
                    }
                }

                offset += messageLength
            }
            return result
        }
    }

    private enum Layout {
        static let indexOffset = MemoryLayout<if_msghdr2>.offset(of: \if_msghdr2.ifm_index)!
        static let flagsOffset = MemoryLayout<if_msghdr2>.offset(of: \if_msghdr2.ifm_flags)!
        static let dataOffset = MemoryLayout<if_msghdr2>.offset(of: \if_msghdr2.ifm_data)!
        static let bytesInOffset = MemoryLayout<if_data64>.offset(of: \if_data64.ifi_ibytes)!
        static let bytesOutOffset = MemoryLayout<if_data64>.offset(of: \if_data64.ifi_obytes)!
        static let packetsInOffset = MemoryLayout<if_data64>.offset(of: \if_data64.ifi_ipackets)!
        static let packetsOutOffset = MemoryLayout<if_data64>.offset(of: \if_data64.ifi_opackets)!
    }

    private static func readUInt64(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        withUnsafeMutableBytes(of: &value) { destination in
            destination.copyBytes(from: UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + 8)]))
        }
        return value
    }
}
