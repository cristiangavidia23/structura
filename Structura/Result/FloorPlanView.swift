import SwiftUI

/// The flat, dimensioned top-down floor plan — always upright, technical-
/// drawing styled. The dollhouse lives in `DollhouseSceneView`; this view
/// only ever draws the plan, so there's no projection math left here beyond
/// scaling the plan to fit the canvas.
struct FloorPlanView: View {
    let plan: FloorPlan
    let unitSystem: UnitSystem

    var body: some View {
        Canvas { context, size in
            guard let fit = Fit(plan: plan, size: size) else { return }

            drawFloor(in: &context, fit: fit)
            for segment in plan.segments {
                drawSegment(segment, in: &context, fit: fit)
            }
            drawFurniture(in: &context, fit: fit)
            drawDimensions(in: &context, fit: fit)
        }
        .accessibilityElement()
        .accessibilityLabel("Plano 2D acotado del ambiente")
    }

    /// Scales and centers the plan in the available space.
    private struct Fit {
        let scale: Double
        let offset: CGSize

        init?(plan: FloorPlan, size: CGSize) {
            guard plan.bounds.width > 0, plan.bounds.height > 0,
                  size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0 else { return nil }

            let inset = min(56.0, min(size.width, size.height) / 4)
            let candidate = min(
                (size.width - inset * 2) / plan.bounds.width,
                (size.height - inset * 2) / plan.bounds.height
            )
            guard candidate.isFinite, candidate > 0 else { return nil }
            scale = candidate
            offset = CGSize(
                width: size.width / 2 - plan.bounds.midX * scale,
                height: size.height / 2 - plan.bounds.midY * scale
            )
        }

        func place(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * scale + offset.width, y: point.y * scale + offset.height)
        }
    }

    // MARK: - Drawing

    /// A room outline traced from the wall chain and filled faintly, so the
    /// plan reads as standing on a floor rather than a set of disconnected lines.
    private func drawFloor(in context: inout GraphicsContext, fit: Fit) {
        let walls = plan.walls
        guard !walls.isEmpty else { return }

        var path = Path()
        path.move(to: fit.place(walls[0].start))
        for wall in walls {
            path.addLine(to: fit.place(wall.end))
        }
        path.closeSubpath()
        context.fill(path, with: .color(Theme.ink.opacity(0.05)))
    }

    private func drawSegment(_ segment: FloorPlan.Segment, in context: inout GraphicsContext, fit: Fit) {
        var path = Path()
        path.move(to: fit.place(segment.start))
        path.addLine(to: fit.place(segment.end))

        context.stroke(
            path,
            with: .color(strokeColor(for: segment)),
            style: StrokeStyle(
                lineWidth: segment.category == .wall ? 2.5 : 2,
                lineCap: .round,
                dash: dash(for: segment)
            )
        )
    }

    private func drawFurniture(in context: inout GraphicsContext, fit: Fit) {
        for item in plan.furniture {
            var path = Path()
            for (index, point) in item.footprint.enumerated() {
                let placed = fit.place(point)
                if index == 0 { path.move(to: placed) } else { path.addLine(to: placed) }
            }
            path.closeSubpath()
            context.fill(path, with: .color(Theme.ink.opacity(0.06)))
            context.stroke(path, with: .color(Theme.ink.opacity(0.28)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
    }

    private func drawDimensions(in context: inout GraphicsContext, fit: Fit) {
        for wall in plan.walls {
            let point = fit.place(wall.midpoint)
            let text = unitSystem.formatLength(meters: wall.lengthMeters)
            let resolved = context.resolve(
                Text(wall.isReliable ? text : "~\(text)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink.opacity(wall.isReliable ? 0.75 : 0.5))
            )
            let bounds = resolved.measure(in: CGSize(width: 200, height: 40))
            let plate = CGRect(
                x: point.x - bounds.width / 2 - 5,
                y: point.y - bounds.height / 2 - 2,
                width: bounds.width + 10,
                height: bounds.height + 4
            )
            context.fill(Path(roundedRect: plate, cornerRadius: 4), with: .color(Theme.paper.opacity(0.9)))
            context.draw(resolved, at: point, anchor: .center)
        }
    }

    // MARK: - Style

    private func strokeColor(for segment: FloorPlan.Segment) -> Color {
        switch segment.category {
        case .wall: return Theme.ink.opacity(segment.isReliable ? 1 : 0.4)
        case .door: return Theme.accent
        case .window: return Theme.accent.opacity(0.65)
        case .opening: return Theme.ink.opacity(0.35)
        }
    }

    /// Dashes mark geometry we did not fully observe: openings by nature, and
    /// walls whose extent RoomPlan inferred rather than measured.
    private func dash(for segment: FloorPlan.Segment) -> [CGFloat] {
        if segment.category == .opening { return [6, 5] }
        return segment.isReliable ? [] : [7, 4]
    }
}
