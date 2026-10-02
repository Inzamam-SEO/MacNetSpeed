import Foundation

enum GraphMode: String, CaseIterable, Identifiable {
    case data
    case packets

    var id: String { rawValue }

    var title: String {
        switch self {
        case .data: "DATA"
        case .packets: "PACKETS"
        }
    }
}

/// Activity Monitor's network units: decimal bytes (1 KB = 1,000 bytes), two fraction digits.
enum NetworkFormat {
    static func bytes(_ value: Double, locale: Locale = .current) -> String {
        magnitude(value, perSecond: false, locale: locale)
    }

    static func speed(_ bytesPerSecond: Double, locale: Locale = .current) -> String {
        magnitude(bytesPerSecond, perSecond: true, locale: locale)
    }

    static func packets(_ value: Double, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        let rounded = Int64(max(0, value).rounded())
        return formatter.string(from: NSNumber(value: rounded)) ?? "\(rounded)"
    }

    static func packetSpeed(_ packetsPerSecond: Double, locale: Locale = .current) -> String {
        let value = max(0, packetsPerSecond)
        if value >= 1000 {
            return String(
                format: "%.2f K/s",
                locale: locale,
                value / 1000
            )
        }
        return String(format: "%.0f /s", locale: locale, value.rounded())
    }

    private static func magnitude(_ value: Double, perSecond: Bool, locale: Locale) -> String {
        let units = ["", "K", "M", "G", "T", "P"]
        var amount = max(0, value)
        var index = 0
        while amount >= 1000, index < units.count - 1 {
            amount /= 1000
            index += 1
        }

        let suffix = perSecond ? "/s" : ""
        if index == 0 {
            let unit = perSecond ? "B/s" : "bytes"
            return String(format: "%.0f %@", locale: locale, amount.rounded(), unit)
        }

        let unit = units[index] + "B" + suffix
        return String(format: "%.2f %@", locale: locale, amount, unit)
    }
}
