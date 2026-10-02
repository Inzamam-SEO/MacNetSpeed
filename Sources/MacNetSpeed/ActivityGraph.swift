import SwiftUI

enum NetworkColor {
    static let download = Color(red: 0.36, green: 0.80, blue: 0.98)
    static let upload = Color(red: 1.0, green: 0.39, blue: 0.42)
}

/// Activity Monitor's network graph: download rises above the center line in blue,
/// upload falls below it in red, and both share one scale.
struct ActivityGraph: View {
    var samples: [RateSample]
    var mode: GraphMode
    var capacity: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            let plot = colorScheme == .dark
                ? Color(red: 0.11, green: 0.11, blue: 0.12)
                : Color(red: 0.97, green: 0.97, blue: 0.98)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(plot))

            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
            let guide = colorScheme == .dark
                ? Color.white.opacity(0.22)
                : Color.black.opacity(0.16)

            func horizontal(_ y: CGFloat) -> Path {
                var path = Path()
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
                return path
            }

            context.stroke(horizontal(rect.minY), with: .color(guide), lineWidth: 1)
            context.stroke(horizontal(rect.midY), with: .color(guide), lineWidth: 1)
            context.stroke(horizontal(rect.maxY), with: .color(guide), lineWidth: 1)

            guard samples.count >= 2 else { return }

            let pairs = samples.map { sample -> (down: Double, up: Double) in
                switch mode {
                case .data:
                    (max(0, sample.bytesDown), max(0, sample.bytesUp))
                case .packets:
                    (max(0, sample.packetsDown), max(0, sample.packetsUp))
                }
            }
            let peak = max(pairs.map(\.down).max() ?? 0, pairs.map(\.up).max() ?? 0, 1)
            let usable = rect.height / 2 - 1.5

            func point(index: Int, value: Double, above: Bool) -> CGPoint {
                let slots = CGFloat(max(capacity - 1, 1))
                let x = rect.maxX - CGFloat(samples.count - 1 - index) * (rect.width / slots)
                let magnitude = CGFloat(value / peak) * usable
                let y = above ? rect.midY - magnitude : rect.midY + magnitude
                return CGPoint(x: x, y: y)
            }

            func series(_ above: Bool) -> Path {
                var path = Path()
                for (index, pair) in pairs.enumerated() {
                    let value = above ? pair.down : pair.up
                    let next = point(index: index, value: value, above: above)
                    if index == 0 {
                        path.move(to: next)
                    } else {
                        path.addLine(to: next)
                    }
                }
                return path
            }

            let style = StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round)
            context.stroke(series(true), with: .color(NetworkColor.download), style: style)
            context.stroke(series(false), with: .color(NetworkColor.upload), style: style)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.primary.opacity(0.16), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}
