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
            drawScaleBar(in: &context, fit: fit, size: size)
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
        var path = Path()
        for polygon in plan.floorPolygons {
            path.move(to: fit.place(polygon[0]))
            for point in polygon.dropFirst() {
                path.addLine(to: fit.place(point))
            }
            path.closeSubpath()
        }
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

    /// A wall shorter than this on screen can't carry a dimension line, its
    /// two ticks and a label without them colliding into a smudge. Those
    /// lengths are still listed in `MeasurementsView` — they're just not
    /// annotated on the drawing, which is what a draftsman would do too.
    private static let minimumAnnotatedWallPoints: CGFloat = 34

    /// How far outside the wall its dimension line sits, in points.
    private static let dimensionOffset: CGFloat = 17

    /// Dimensions drawn the way a floor plan actually dimensions things:
    /// witness lines leaving the wall, a dimension line running parallel to
    /// it *outside* the drawing, 45° ticks where they meet, and the figure
    /// sitting on the line and rotated with it.
    ///
    /// The previous version stamped each length on its wall's midpoint over
    /// an opaque plate, which put every figure on top of the very geometry
    /// it measured and hid a piece of each wall behind it.
    private func drawDimensions(in context: inout GraphicsContext, fit: Fit) {
        let planCenter = fit.place(CGPoint(x: plan.bounds.midX, y: plan.bounds.midY))

        for wall in plan.walls {
            let start = fit.place(wall.start)
            let end = fit.place(wall.end)
            let run = CGVector(dx: end.x - start.x, dy: end.y - start.y)
            let length = hypot(run.dx, run.dy)
            guard length >= Self.minimumAnnotatedWallPoints else { continue }

            // Perpendicular to the wall, flipped to point away from the middle
            // of the plan, so dimensions always land outside the rooms rather
            // than across them.
            var normal = CGVector(dx: -run.dy / length, dy: run.dx / length)
            let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            if (midpoint.x - planCenter.x) * normal.dx + (midpoint.y - planCenter.y) * normal.dy < 0 {
                normal = CGVector(dx: -normal.dx, dy: -normal.dy)
            }

            let offset = Self.dimensionOffset
            let dimensionStart = CGPoint(x: start.x + normal.dx * offset, y: start.y + normal.dy * offset)
            let dimensionEnd = CGPoint(x: end.x + normal.dx * offset, y: end.y + normal.dy * offset)
            let hairline = Theme.ink.opacity(wall.isReliable ? 0.45 : 0.28)

            // Witness lines: start just off the wall so they read as
            // annotation rather than as more geometry, and overshoot the
            // dimension line slightly, as drawn by convention.
            var witness = Path()
            for (wallEnd, dimensionEndPoint) in [(start, dimensionStart), (end, dimensionEnd)] {
                witness.move(to: CGPoint(x: wallEnd.x + normal.dx * 3, y: wallEnd.y + normal.dy * 3))
                witness.addLine(to: CGPoint(x: dimensionEndPoint.x + normal.dx * 4, y: dimensionEndPoint.y + normal.dy * 4))
            }
            context.stroke(witness, with: .color(hairline), style: StrokeStyle(lineWidth: 0.75))

            var dimensionLine = Path()
            dimensionLine.move(to: dimensionStart)
            dimensionLine.addLine(to: dimensionEnd)
            context.stroke(dimensionLine, with: .color(hairline), style: StrokeStyle(lineWidth: 0.75))

            // 45° slash ticks — the architectural convention, and legible at
            // small sizes where arrowheads turn into blobs.
            let unit = CGVector(dx: run.dx / length, dy: run.dy / length)
            let tick = CGVector(
                dx: (unit.dx + normal.dx) * 3.5,
                dy: (unit.dy + normal.dy) * 3.5
            )
            var ticks = Path()
            for point in [dimensionStart, dimensionEnd] {
                ticks.move(to: CGPoint(x: point.x - tick.dx, y: point.y - tick.dy))
                ticks.addLine(to: CGPoint(x: point.x + tick.dx, y: point.y + tick.dy))
            }
            context.stroke(ticks, with: .color(hairline), style: StrokeStyle(lineWidth: 1))

            drawDimensionFigure(for: wall, on: (dimensionStart, dimensionEnd), normal: normal, in: &context)
        }
    }

    /// The figure itself, rotated to sit along its dimension line and always
    /// kept right-side up.
    private func drawDimensionFigure(
        for wall: FloorPlan.Segment,
        on line: (start: CGPoint, end: CGPoint),
        normal: CGVector,
        in context: inout GraphicsContext
    ) {
        let text = unitSystem.formatLength(meters: wall.lengthMeters)
        let resolved = context.resolve(
            Text(wall.isReliable ? text : "~\(text)")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.ink.opacity(wall.isReliable ? 0.8 : 0.5))
        )

        var angle = atan2(line.end.y - line.start.y, line.end.x - line.start.x)
        // Text set along a line running right-to-left would otherwise render
        // upside down; flipping by π keeps every figure readable from the
        // same side of the sheet.
        if angle > .pi / 2 || angle < -.pi / 2 { angle += .pi }

        let center = CGPoint(
            x: (line.start.x + line.end.x) / 2 + normal.dx * 8,
            y: (line.start.y + line.end.y) / 2 + normal.dy * 8
        )
        context.drawLayer { layer in
            layer.translateBy(x: center.x, y: center.y)
            layer.rotate(by: .radians(angle))
            layer.draw(resolved, at: .zero, anchor: .center)
        }
    }

    /// A graphic scale, so the drawing still communicates its size when it's
    /// screenshotted, exported, or printed at whatever size — which a
    /// per-wall figure alone doesn't do.
    ///
    /// Deliberately *not* accompanied by a north arrow: Pro Scan runs with
    /// `worldAlignment = .gravity`, which plumbs the vertical axis but leaves
    /// the horizontal orientation arbitrary, so the drawing genuinely does
    /// not know where north is. Drawing one anyway is the kind of fabricated
    /// precision this project avoids elsewhere.
    private func drawScaleBar(in context: inout GraphicsContext, fit: Fit, size: CGSize) {
        // Round lengths in whatever unit the user reads, not a converted
        // metric number that lands on something like "3.3 ft".
        let candidatesMeters: [Double] = unitSystem == .metric
            ? [0.5, 1, 2, 5, 10, 20]
            : [1, 2, 5, 10, 20, 50].map { $0 * 0.3048 }
        // The longest round length that still fits comfortably on the sheet.
        guard let barMeters = candidatesMeters.last(where: { $0 * fit.scale <= min(132, size.width * 0.38) }) else { return }
        let barPoints = barMeters * fit.scale
        guard barPoints >= 26 else { return }

        let origin = CGPoint(x: 18, y: size.height - 20)
        let ink = Theme.ink.opacity(0.55)

        var bar = Path()
        bar.move(to: origin)
        bar.addLine(to: CGPoint(x: origin.x + barPoints, y: origin.y))
        context.stroke(bar, with: .color(ink), style: StrokeStyle(lineWidth: 1))

        var ticks = Path()
        for x in [origin.x, origin.x + barPoints / 2, origin.x + barPoints] {
            let half: CGFloat = x == origin.x + barPoints / 2 ? 2.5 : 4
            ticks.move(to: CGPoint(x: x, y: origin.y - half))
            ticks.addLine(to: CGPoint(x: x, y: origin.y + half))
        }
        context.stroke(ticks, with: .color(ink), style: StrokeStyle(lineWidth: 1))

        context.draw(
            context.resolve(
                Text(unitSystem.formatLength(meters: barMeters))
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(ink)
            ),
            at: CGPoint(x: origin.x, y: origin.y - 9),
            anchor: .bottomLeading
        )
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
