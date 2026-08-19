import SwiftUI

/// A simple line-art room outline used as onboarding decoration. Unlike the
/// paywall (which can use the user's own scan), there's no real data yet at
/// this point in the flow — this stands in for it without resorting to a
/// generic stock icon or illustration.
struct SketchBackdrop: View {
    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 48
            let side = min(size.width, size.height * 0.6) - inset * 2
            let rect = CGRect(
                x: (size.width - side) / 2,
                y: size.height * 0.12,
                width: side,
                height: side
            )

            var room = Path()
            room.move(to: CGPoint(x: rect.minX, y: rect.minY))
            room.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            room.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            room.addLine(to: CGPoint(x: rect.minX + rect.width * 0.32, y: rect.maxY))
            room.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.28))
            room.closeSubpath()
            context.stroke(room, with: .color(Theme.ink), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

            // A doorway gap and an interior partition, just enough to read as a plan.
            var partition = Path()
            partition.move(to: CGPoint(x: rect.minX + rect.width * 0.55, y: rect.minY))
            partition.addLine(to: CGPoint(x: rect.minX + rect.width * 0.55, y: rect.minY + rect.height * 0.45))
            context.stroke(partition, with: .color(Theme.ink.opacity(0.6)), style: StrokeStyle(lineWidth: 1.5))

            var dimensionLine = Path()
            dimensionLine.move(to: CGPoint(x: rect.minX, y: rect.minY - 14))
            dimensionLine.addLine(to: CGPoint(x: rect.maxX, y: rect.minY - 14))
            context.stroke(dimensionLine, with: .color(Theme.ink.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }
}
