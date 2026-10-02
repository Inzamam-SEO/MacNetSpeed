import AppKit
import CoreText
import Observation
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let monitor: NetworkMonitor
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var lastStatusText = ""

    init(monitor: NetworkMonitor) {
        self.monitor = monitor
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor.start()
        LoginItem.syncPreferredState()
        installStatusItem()
        watchSpeeds()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleNone
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let hosting = PanelHostingController(rootView: NetworkPanel(monitor: monitor))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        self.popover = popover
        updateStatusImage()
    }

    private func watchSpeeds() {
        withObservationTracking {
            _ = monitor.downloadBytesPerSecond
            _ = monitor.uploadBytesPerSecond
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateStatusImage()
                self?.watchSpeeds()
            }
        }
    }

    private func updateStatusImage() {
        let download = NetworkFormat.speed(monitor.downloadBytesPerSecond)
        let upload = NetworkFormat.speed(monitor.uploadBytesPerSecond)
        let text = "\(download)|\(upload)"
        guard text != lastStatusText else { return }
        lastStatusText = text
        let image = StatusSpeedImage.make(download: download, upload: upload)
        statusItem?.length = image.size.width
        statusItem?.button?.image = image
        statusItem?.button?.setAccessibilityLabel("Download \(download), upload \(upload)")
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    func popoverDidClose(_ notification: Notification) {
        monitor.showApps = false
    }
}

/// Hosts the panel and resizes it in one step. An animated popover resize is what
/// made the app list feel stuck while it opened and closed.
final class PanelHostingController: NSHostingController<NetworkPanel> {
    override func viewWillLayout() {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        super.viewWillLayout()
        NSAnimationContext.endGrouping()
    }
}

@MainActor
enum StatusSpeedImage {
    /// Slightly under the menu-bar height so both lines stay clear.
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

    /// Ink above and below the baseline, so the two rows can be separated by a real gap.
    private static let ink: (above: CGFloat, below: CGFloat) = {
        let sample = line("↓ 0", font: font, red: 0, green: 0, blue: 0)
        let bounds = CTLineGetImageBounds(CTLineCreateWithAttributedString(sample), nil)
        return (bounds.maxY, -bounds.minY)
    }()

    /// Wide enough for the longest normal reading, so the item never grows or shrinks.
    private static let fixedWidth: CGFloat = {
        let samples = [
            "↓ 999.99 KB/s",
            "↓ 999.99 MB/s",
            "↓ 999.99 GB/s",
            "↓ 999.99 TB/s",
            "↓ 1000 B/s",
        ]
        let widest = samples.map { sample in
            line(sample, font: font, red: 0, green: 0, blue: 0).size().width
        }.max() ?? 1
        return ceil(widest) + 2
    }()

    /// Both rates share one status icon. Text is right-aligned in a fixed width,
    /// so a change from 9.40 KB/s to 113.45 KB/s grows to the left and the units stay put.
    static func make(download: String, upload: String) -> NSImage {
        let down = line("↓ \(download)", font: font, red: 0.36, green: 0.80, blue: 0.98)
        let up = line("↑ \(upload)", font: font, red: 1, green: 0.39, blue: 0.42)
        let width = max(fixedWidth, ceil(max(down.size().width, up.size().width)) + 2)
        let height = NSStatusBar.system.thickness
        let inkHeight = ink.above + ink.below
        let gap = min(2.25, max(0, height - inkHeight * 2))
        let slack = max(0, height - inkHeight * 2 - gap)
        let uploadBaseline = ink.below + slack / 2
        let downloadBaseline = uploadBaseline + inkHeight + gap
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(down, in: context, at: CGPoint(x: width - down.size().width - 1, y: downloadBaseline))
            draw(up, in: context, at: CGPoint(x: width - up.size().width - 1, y: uploadBaseline))
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func line(_ text: String, font: NSFont, red: CGFloat, green: CGFloat, blue: CGFloat) -> NSAttributedString {
        let color = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
        ])
    }

    private static func draw(_ text: NSAttributedString, in context: CGContext, at baseline: CGPoint) {
        context.textMatrix = .identity
        context.textPosition = baseline
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
    }
}
