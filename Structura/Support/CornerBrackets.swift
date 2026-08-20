import SwiftUI

/// Four L-shaped corner marks, like crop marks on a technical drawing or a
/// camera viewfinder reticle — used instead of a plain rounded-rect border to
/// frame content that should read as "measured" rather than just "boxed."
struct CornerBrackets: View {
    var color: Color = Theme.ink
    var length: CGFloat = 14
    var thickness: CGFloat = 1.5
    var inset: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            Path { path in
                // Top-left
                path.move(to: CGPoint(x: inset, y: inset + length))
                path.addLine(to: CGPoint(x: inset, y: inset))
                path.addLine(to: CGPoint(x: inset + length, y: inset))
                // Top-right
                path.move(to: CGPoint(x: w - inset - length, y: inset))
                path.addLine(to: CGPoint(x: w - inset, y: inset))
                path.addLine(to: CGPoint(x: w - inset, y: inset + length))
                // Bottom-right
                path.move(to: CGPoint(x: w - inset, y: h - inset - length))
                path.addLine(to: CGPoint(x: w - inset, y: h - inset))
                path.addLine(to: CGPoint(x: w - inset - length, y: h - inset))
                // Bottom-left
                path.move(to: CGPoint(x: inset + length, y: h - inset))
                path.addLine(to: CGPoint(x: inset, y: h - inset))
                path.addLine(to: CGPoint(x: inset, y: h - inset - length))
            }
            .stroke(color, style: StrokeStyle(lineWidth: thickness, lineCap: .round))
        }
        .allowsHitTesting(false)
    }
}
