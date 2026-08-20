import SwiftUI

/// Renders the room as an axonometric line drawing that flattens continuously
/// into the dimensioned floor plan.
///
/// Both states are the same geometry under one projection: as `progress` goes to
/// 1 the camera tilts to straight-down and wall heights collapse to zero, so the
/// dollhouse *becomes* the plan rather than cross-fading into a separate view.
struct RoomMorphView: View, Animatable {
    let plan: FloorPlan
    let unitSystem: UnitSystem
    /// 0 = dollhouse, 1 = flat dimensioned plan.
    var progress: Double

    @State private var yaw: Double = -0.45
    @GestureState private var dragYaw: Double = 0

    private let dollhousePitch = 55 * Double.pi / 180

    /// A `Canvas` does not interpolate values captured by its draw closure, so the
    /// morph would snap between states. Exposing progress as the view's animatable
    /// data makes SwiftUI drive body through every intermediate frame instead.
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let projection = currentProjection
            let prisms = buildPrisms()
            guard let fit = Fit(prisms: prisms, projection: projection, size: size) else { return }

            drawFloor(in: &context, projection: projection, fit: fit)

            for prism in prisms.sorted(by: { $0.depth(in: projection) < $1.depth(in: projection) }) {
                draw(prism, in: &context, projection: projection, fit: fit)
            }

            drawDimensions(in: &context, projection: projection, fit: fit)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .updating($dragYaw) { value, state, _ in
                    state = value.translation.width / 110
                }
                .onEnded { value in
                    yaw += value.translation.width / 110
                }
        )
        // The Canvas draws pixels with no inherent accessibility tree, so without
        // this VoiceOver sees nothing here at all — not even a label. The rotate
        // gesture also has no VoiceOver equivalent by default, hence the
        // adjustable action as a swipe-up/down substitute.
        .accessibilityElement()
        .accessibilityLabel("Modelo del ambiente")
        .accessibilityValue(progress < 0.5 ? "Vista 3D" : "Plano 2D acotado")
        .accessibilityHint(progress < 0.5 ? "Ajustable para rotar la vista" : "")
        .accessibilityAdjustableAction { direction in
            guard progress < 0.5 else { return }
            switch direction {
            case .increment: yaw += 0.3
            case .decrement: yaw -= 0.3
            @unknown default: break
            }
        }
    }

    // MARK: - Projection

    private var currentProjection: Projection {
        Projection(
            // Unwind the user's rotation as the plan flattens so it settles upright.
            yaw: (yaw + dragYaw) * (1 - progress),
            pitch: dollhousePitch + (.pi / 2 - dollhousePitch) * progress,
            heightScale: 1 - progress
        )
    }

    /// Axonometric camera: no perspective divide, which keeps parallel walls
    /// parallel — the convention technical drawings are read in.
    private struct Projection {
        let yaw: Double
        let pitch: Double
        let heightScale: Double

        func rotatedDepth(_ point: CGPoint) -> Double {
            point.x * sin(yaw) + point.y * cos(yaw)
        }

        func project(_ point: CGPoint, height: Double) -> CGPoint {
            let x = point.x * cos(yaw) - point.y * sin(yaw)
            let depth = rotatedDepth(point)
            return CGPoint(
                x: x,
                y: depth * sin(pitch) - height * heightScale * cos(pitch)
            )
        }
    }

    /// Scales and centres the projected drawing in the available space. Recomputed
    /// per frame; because the geometry changes continuously so does the fit, which
    /// reads as a gentle zoom rather than a jump.
    private struct Fit {
        let scale: Double
        let offset: CGSize

        init?(prisms: [Prism], projection: Projection, size: CGSize) {
            // Degenerate scans can yield non-finite coordinates; letting those reach
            // CoreGraphics produces invalid-value errors rather than a drawing.
            let projected = prisms.flatMap { $0.projectedPoints(with: projection) }
                .filter { $0.x.isFinite && $0.y.isFinite }
            guard !projected.isEmpty,
                  size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0 else { return nil }

            let xs = projected.map(\.x)
            let ys = projected.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max() else { return nil }

            let inset = min(64.0, min(size.width, size.height) / 4)
            let width = max(maxX - minX, 0.01)
            let height = max(maxY - minY, 0.01)
            let candidate = min((size.width - inset * 2) / width, (size.height - inset * 2) / height)
            guard candidate.isFinite, candidate > 0 else { return nil }
            scale = candidate
            offset = CGSize(
                width: size.width / 2 - (minX + maxX) / 2 * scale,
                height: size.height / 2 - (minY + maxY) / 2 * scale
            )
        }

        func place(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * scale + offset.width, y: point.y * scale + offset.height)
        }
    }

    // MARK: - Geometry

    private struct Prism {
        enum Kind {
            case surface(FloorPlan.Segment)
            case furniture
        }

        let kind: Kind
        let footprint: [CGPoint]
        let base: Double
        let top: Double

        func projectedPoints(with projection: Projection) -> [CGPoint] {
            footprint.map { projection.project($0, height: base) }
                + footprint.map { projection.project($0, height: top) }
        }

        func depth(in projection: Projection) -> Double {
            guard !footprint.isEmpty else { return 0 }
            return footprint.map(projection.rotatedDepth).reduce(0, +) / Double(footprint.count)
        }
    }

    private func buildPrisms() -> [Prism] {
        var prisms = plan.segments.map { segment in
            Prism(
                kind: .surface(segment),
                footprint: [segment.start, segment.end],
                base: segment.baseHeightMeters,
                top: segment.baseHeightMeters + segment.heightMeters
            )
        }
        prisms += plan.furniture.map { item in
            Prism(
                kind: .furniture,
                footprint: item.footprint,
                base: item.baseHeightMeters,
                top: item.baseHeightMeters + item.heightMeters
            )
        }
        return prisms
    }

    // MARK: - Drawing

    private func draw(_ prism: Prism, in context: inout GraphicsContext, projection: Projection, fit: Fit) {
        switch prism.kind {
        case .surface(let segment):
            drawSurface(segment, prism: prism, in: &context, projection: projection, fit: fit)
        case .furniture:
            drawFurniture(prism, in: &context, projection: projection, fit: fit)
        }
    }

    private func drawSurface(
        _ segment: FloorPlan.Segment,
        prism: Prism,
        in context: inout GraphicsContext,
        projection: Projection,
        fit: Fit
    ) {
        let baseStart = fit.place(projection.project(segment.start, height: prism.base))
        let baseEnd = fit.place(projection.project(segment.end, height: prism.base))
        let topEnd = fit.place(projection.project(segment.end, height: prism.top))
        let topStart = fit.place(projection.project(segment.start, height: prism.top))

        var face = Path()
        face.move(to: baseStart)
        face.addLine(to: baseEnd)
        face.addLine(to: topEnd)
        face.addLine(to: topStart)
        face.closeSubpath()

        // The face has area only while the room still has height; at the end of
        // the morph it degenerates to the plan's line. Opacity also carries a
        // two-tone pseudo-lighting factor by wall orientation — walls running
        // one way read lighter, the perpendicular ones darker — which is what
        // actually reads as volume in an axonometric drawing with no real
        // light source to shade from.
        let fillOpacity = 0.36 * lightingFactor(for: segment) * (1 - progress)
        if fillOpacity > 0.001 {
            context.fill(face, with: .color(strokeColor(for: segment).opacity(fillOpacity)))
        }

        var outline = Path()
        outline.move(to: baseStart)
        outline.addLine(to: baseEnd)
        if progress < 0.999 {
            outline.move(to: topStart)
            outline.addLine(to: topEnd)
            outline.move(to: baseStart)
            outline.addLine(to: topStart)
            outline.move(to: baseEnd)
            outline.addLine(to: topEnd)
        }

        context.stroke(
            outline,
            with: .color(strokeColor(for: segment)),
            style: StrokeStyle(
                lineWidth: segment.category == .wall ? 2.5 : 2,
                lineCap: .round,
                dash: dash(for: segment)
            )
        )
    }

    private func drawFurniture(
        _ prism: Prism,
        in context: inout GraphicsContext,
        projection: Projection,
        fit: Fit
    ) {
        func polygon(atHeight height: Double) -> Path {
            var path = Path()
            for (index, point) in prism.footprint.enumerated() {
                let placed = fit.place(projection.project(point, height: height))
                if index == 0 { path.move(to: placed) } else { path.addLine(to: placed) }
            }
            path.closeSubpath()
            return path
        }

        let color = Theme.ink.opacity(0.28)
        let lineStyle = StrokeStyle(lineWidth: 1.2, lineCap: .round)

        context.fill(polygon(atHeight: prism.top), with: .color(Theme.ink.opacity(0.08 * (1 - progress))))
        context.stroke(polygon(atHeight: prism.top), with: .color(color), style: lineStyle)

        guard progress < 0.999 else { return }

        context.stroke(polygon(atHeight: prism.base), with: .color(color), style: lineStyle)
        var edges = Path()
        for point in prism.footprint {
            edges.move(to: fit.place(projection.project(point, height: prism.base)))
            edges.addLine(to: fit.place(projection.project(point, height: prism.top)))
        }
        context.stroke(edges, with: .color(color), style: lineStyle)
    }

    private func drawDimensions(in context: inout GraphicsContext, projection: Projection, fit: Fit) {
        // Hold the dimensions back until the room is nearly flat, so they read as
        // the payoff of the morph instead of clutter during it.
        let opacity = max(0, (progress - 0.55) / 0.45)
        guard opacity > 0.01 else { return }

        for wall in plan.walls {
            let point = fit.place(projection.project(wall.midpoint, height: wall.baseHeightMeters))
            let text = unitSystem.formatLength(meters: wall.lengthMeters)
            let resolved = context.resolve(
                Text(wall.isReliable ? text : "~\(text)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink.opacity((wall.isReliable ? 0.75 : 0.5) * opacity))
            )
            let bounds = resolved.measure(in: CGSize(width: 200, height: 40))
            let plate = CGRect(
                x: point.x - bounds.width / 2 - 5,
                y: point.y - bounds.height / 2 - 2,
                width: bounds.width + 10,
                height: bounds.height + 4
            )
            context.fill(
                Path(roundedRect: plate, cornerRadius: 4),
                with: .color(Theme.paper.opacity(0.9 * opacity))
            )
            context.draw(resolved, at: point, anchor: .center)
        }
    }

    // MARK: - Style

    /// Two fixed shades by the wall's orientation in the room's own frame
    /// (not the camera's), so it stays consistent as the user rotates the view.
    private func lightingFactor(for segment: FloorPlan.Segment) -> Double {
        abs(cos(segment.angle)) > abs(sin(segment.angle)) ? 1.0 : 0.6
    }

    /// A room outline traced from the wall chain and filled faintly, so the
    /// dollhouse reads as standing on a floor rather than a set of walls
    /// floating over nothing.
    private func drawFloor(in context: inout GraphicsContext, projection: Projection, fit: Fit) {
        let walls = plan.walls
        guard !walls.isEmpty else { return }

        var path = Path()
        let firstPoint = fit.place(projection.project(walls[0].start, height: walls[0].baseHeightMeters))
        path.move(to: firstPoint)
        for wall in walls {
            let point = fit.place(projection.project(wall.end, height: wall.baseHeightMeters))
            guard point.x.isFinite, point.y.isFinite else { continue }
            path.addLine(to: point)
        }
        path.closeSubpath()

        context.fill(path, with: .color(Theme.ink.opacity(0.05)))
    }

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
