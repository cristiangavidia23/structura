import SwiftUI

/// Renders a scan's walls as faint static line art — the paywall and onboarding
/// use the user's own captured geometry as decoration instead of a generic icon
/// or illustration.
struct BlueprintBackdrop: View {
    let plan: FloorPlan

    var body: some View {
        Canvas { context, size in
            guard plan.bounds.width > 0, plan.bounds.height > 0 else { return }

            let inset: CGFloat = 24
            let scale = min(
                (size.width - inset * 2) / plan.bounds.width,
                (size.height - inset * 2) / plan.bounds.height
            )
            guard scale.isFinite, scale > 0 else { return }

            let offset = CGSize(
                width: size.width / 2 - plan.bounds.midX * scale,
                height: size.height / 2 - plan.bounds.midY * scale
            )

            for segment in plan.segments {
                var path = Path()
                path.move(to: CGPoint(
                    x: segment.start.x * scale + offset.width,
                    y: segment.start.y * scale + offset.height
                ))
                path.addLine(to: CGPoint(
                    x: segment.end.x * scale + offset.width,
                    y: segment.end.y * scale + offset.height
                ))
                context.stroke(path, with: .color(Theme.ink), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
    }
}
