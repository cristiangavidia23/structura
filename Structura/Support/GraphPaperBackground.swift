import SwiftUI

/// A faint graph-paper grid — this is a measuring tool, so the background
/// itself should read as a drafting surface rather than a flat, generic fill.
struct GraphPaperBackground: View {
    var body: some View {
        Canvas { context, size in
            let minorSpacing: CGFloat = 16
            let majorEvery = 4

            var minor = Path()
            var major = Path()

            var index = 0
            var x: CGFloat = 0
            while x <= size.width {
                let line = index % majorEvery == 0 ? major : minor
                _ = line
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                if index % majorEvery == 0 { major.addPath(path) } else { minor.addPath(path) }
                x += minorSpacing
                index += 1
            }

            index = 0
            var y: CGFloat = 0
            while y <= size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                if index % majorEvery == 0 { major.addPath(path) } else { minor.addPath(path) }
                y += minorSpacing
                index += 1
            }

            context.stroke(minor, with: .color(Theme.ink.opacity(0.035)), lineWidth: 1)
            context.stroke(major, with: .color(Theme.ink.opacity(0.06)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}
