import AppKit
import SwiftUI

@main
struct MacNetSpeedMain {
    static func main() {
        if CommandLine.arguments.contains("--dump") {
            NetworkDump.run()
            return
        }
        if CommandLine.arguments.contains("--apps") {
            AppTrafficDump.run()
            return
        }
        if let renderFlag = CommandLine.arguments.firstIndex(of: "--render"),
           CommandLine.arguments.indices.contains(renderFlag + 1) {
            let path = CommandLine.arguments[renderFlag + 1]
            PanelPreview.write(to: path)
            let appsPath = URL(fileURLWithPath: path)
                .deletingPathExtension()
                .appendingPathExtension("apps.png")
                .path
            PanelPreview.writeApps(to: appsPath)
            return
        }

        let bundleID = Bundle.main.bundleIdentifier
        if let bundleID {
            let duplicates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != getpid() }
            if !duplicates.isEmpty {
                duplicates.first?.activate(options: [])
                exit(0)
            }
        }

        let app = NSApplication.shared
        let controller = MainActor.assumeIsolated {
            StatusBarController(monitor: NetworkMonitor())
        }
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

enum PanelPreview {
    @MainActor
    static func write(to path: String) {
        let monitor = NetworkMonitor()
        monitor.installPreviewFixture()
        let panel = NetworkPanel(monitor: monitor)
            .environment(\.colorScheme, .dark)
            .frame(width: 400)
        let host = NSHostingView(rootView: panel)
        host.appearance = NSAppearance(named: .darkAqua)
        let size = host.fittingSize
        host.frame = NSRect(x: 0, y: 0, width: max(size.width, 400), height: max(size.height, 220))
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            fputs("Could not render the panel.\n", stderr)
            exit(1)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            fputs("Could not encode the panel.\n", stderr)
            exit(1)
        }
        let status = StatusSpeedImage.make(download: "183.57 KB/s", upload: "131.54 KB/s")
        do {
            try png.write(to: URL(fileURLWithPath: path))
            if let statusPNG = pngData(from: status) {
                let statusURL = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("status.png")
                try statusPNG.write(to: statusURL)
            }
        } catch {
            fputs("\(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    static func writeApps(to path: String) {
        let monitor = NetworkMonitor()
        monitor.installPreviewFixture()
        monitor.installPreviewApps()
        let panel = NetworkPanel(monitor: monitor)
            .environment(\.colorScheme, .dark)
            .frame(width: 400)
        let host = NSHostingView(rootView: panel)
        host.appearance = NSAppearance(named: .darkAqua)
        let size = host.fittingSize
        host.frame = NSRect(x: 0, y: 0, width: max(size.width, 400), height: max(size.height, 220))
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            fputs("Could not render the panel.\n", stderr)
            exit(1)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            fputs("Could not encode the panel.\n", stderr)
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            fputs("\(error)\n", stderr)
            exit(1)
        }
    }

    private static func pngData(from image: NSImage) -> Data? {
        let scale: CGFloat = 8
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let canvas = NSImage(size: size, flipped: false) { rect in
            NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1).setFill()
            rect.fill()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        guard let tiff = canvas.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

enum NetworkDump {
    static func run() {
        let first = NetworkCounters.snapshot()
        Thread.sleep(forTimeInterval: 1)
        let second = NetworkCounters.snapshot()
        let before = NetworkCounters.totals(from: first.interfaces, selection: NetworkCounters.allInterfaces)
        let after = NetworkCounters.totals(from: second.interfaces, selection: NetworkCounters.allInterfaces)
        let down = Double(NetworkCounters.delta(current: after.bytesIn, previous: before.bytesIn))
        let up = Double(NetworkCounters.delta(current: after.bytesOut, previous: before.bytesOut))

        print("Data received: \(NetworkFormat.bytes(Double(after.bytesIn), locale: Locale(identifier: "en_US_POSIX")))")
        print("Data sent:     \(NetworkFormat.bytes(Double(after.bytesOut), locale: Locale(identifier: "en_US_POSIX")))")
        print("Download:      \(NetworkFormat.speed(down, locale: Locale(identifier: "en_US_POSIX")))")
        print("Upload:        \(NetworkFormat.speed(up, locale: Locale(identifier: "en_US_POSIX")))")
        print("Interfaces:")
        for interface in second.interfaces where !interface.isLoopback {
            let name = second.displayNames[interface.name] ?? interface.name
            print(
                "  \(interface.name) \(name)  in=\(interface.bytesIn) out=\(interface.bytesOut) packets in=\(interface.packetsIn) out=\(interface.packetsOut)"
            )
        }
    }
}
