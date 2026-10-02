import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let size = CGFloat(1024)
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    let background = NSBezierPath(roundedRect: rect.insetBy(dx: 16, dy: 16), xRadius: 224, yRadius: 224)
    NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).setFill()
    background.fill()

    let plot = rect.insetBy(dx: 150, dy: 230)
    NSColor(calibratedWhite: 1, alpha: 0.14).setStroke()
    let axis = NSBezierPath()
    axis.lineWidth = 8
    for fraction in [0.0, 0.5, 1.0] as [CGFloat] {
        let y = plot.minY + plot.height * fraction
        axis.move(to: NSPoint(x: plot.minX, y: y))
        axis.line(to: NSPoint(x: plot.maxX, y: y))
    }
    axis.stroke()

    func stroke(_ values: [CGFloat], above: Bool, color: NSColor) {
        let path = NSBezierPath()
        path.lineWidth = 28
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let step = plot.width / CGFloat(values.count - 1)
        let mid = plot.midY
        for (index, value) in values.enumerated() {
            let x = plot.minX + CGFloat(index) * step
            let y = above ? mid + value * (plot.height * 0.42) : mid - value * (plot.height * 0.42)
            let point = NSPoint(x: x, y: y)
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        color.setStroke()
        path.stroke()
    }

    let down: [CGFloat] = [0.08, 0.12, 0.55, 0.95, 0.35, 0.18, 0.42, 0.22, 0.1]
    let up: [CGFloat] = [0.05, 0.2, 0.3, 0.62, 0.48, 0.15, 0.12, 0.28, 0.08]
    stroke(down, above: true, color: NSColor(calibratedRed: 0.36, green: 0.80, blue: 0.98, alpha: 1))
    stroke(up, above: false, color: NSColor(calibratedRed: 1, green: 0.39, blue: 0.42, alpha: 1))
    return true
}

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else {
    fputs("Could not draw the icon.\n", stderr)
    exit(1)
}

do {
    try png.write(to: URL(fileURLWithPath: output))
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
