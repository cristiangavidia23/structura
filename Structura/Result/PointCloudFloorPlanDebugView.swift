#if DEBUG
import SwiftUI

/// Debug-only preview of `PointCloudFloorPlanBuilder`'s output — F4 of the
/// architecture audit's plan of action.
///
/// This is deliberately **not** wired into `FloorPlanView`/`Mode.plan`: the
/// builder's algorithm has synthetic-data test coverage only, no validation
/// against a real LiDAR scan of an imperfect, furnished room yet (see
/// `claude/f1-progreso.md`, section F4). Compiled only into `#if DEBUG`
/// builds so it can never reach a real user before that validation happens
/// — Cristian's own explicit choice over "show it side-by-side" or
/// "replace `FloorPlanView`" when asked how to surface this.
struct PointCloudFloorPlanDebugView: View {
    let plyURL: URL
    /// RoomPlan's plan for the same scan, when there is one. Used only as a
    /// registration target and drawn underneath for comparison — never mixed
    /// into the point-cloud plan's own geometry.
    var reference: FloorPlan?

    @State private var result: PointCloudFloorPlanBuilder.Result?
    @State private var registration: FloorPlanRegistration.Result?
    @State private var pointCount: Int?
    @State private var didAttemptLoad = false

    var body: some View {
        VStack(spacing: 8) {
            Label("Plano experimental — nube propia, sin validar en dispositivo", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            Group {
                if let result {
                    Canvas { context, size in
                        draw(result, in: &context, size: size)
                    }
                    .accessibilityLabel("Plano experimental derivado de la nube de puntos")
                } else if didAttemptLoad {
                    Text("No se pudo derivar un plano de esta nube de puntos.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink.opacity(0.6))
                } else {
                    ProgressView("Calculando plano…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let result, let pointCount {
                VStack(spacing: 2) {
                    Text("\(result.wallSegments.count) paredes · \(result.polygons.count) polígono(s) · \(pointCount) puntos")
                    if let registration {
                        // Stated, not hidden: an overlay that looks aligned is
                        // persuasive whether or not the fit deserves it, so
                        // the fit's own error is shown next to it.
                        Text(
                            String(
                                format: "Ajuste contra RoomPlan: %.2f m de error medio · %d%% de paredes coincidentes",
                                registration.medianResidualMeters,
                                Int(registration.inlierFraction * 100)
                            )
                        )
                        .foregroundStyle(registration.isTrustworthy ? Theme.ink.opacity(0.5) : .orange)
                    } else if reference != nil {
                        Text("No se pudo alinear con el plano de RoomPlan")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
                .foregroundStyle(Theme.ink.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .task(id: plyURL) {
            await load()
        }
    }

    private func load() async {
        didAttemptLoad = false
        result = nil
        registration = nil
        let url = plyURL
        let referenceWalls = reference.map { plan in
            plan.walls.map {
                FloorPlanRegistration.Segment2D(
                    start: SIMD2(Float($0.start.x), Float($0.start.y)),
                    end: SIMD2(Float($0.end.x), Float($0.end.y))
                )
            }
        }

        let loaded: (PointCloudFloorPlanBuilder.Result?, Int?, FloorPlanRegistration.Result?)
        loaded = await Task.detached(priority: .userInitiated) {
            guard let points = PLYPointCloudReader.read(from: url) else { return (nil, nil, nil) }
            guard let built = PointCloudFloorPlanBuilder.build(from: points) else { return (nil, points.count, nil) }

            // Pro Scan and RoomPlan ran as separate ARKit sessions, so their
            // origins are unrelated — without solving for the transform
            // between them, drawing one over the other would just be two
            // plans in two frames on one canvas.
            var fit: FloorPlanRegistration.Result?
            if let referenceWalls, !referenceWalls.isEmpty {
                let cloudWalls = built.wallSegments.map {
                    FloorPlanRegistration.Segment2D(start: $0.start, end: $0.end)
                }
                fit = FloorPlanRegistration.align(cloudWalls, to: referenceWalls)
            }
            return (built, points.count, fit)
        }.value

        result = loaded.0
        pointCount = loaded.1
        registration = loaded.2
        didAttemptLoad = true
    }

    /// Minimal top-down rendering — not shared with `FloorPlanView`'s
    /// drawing code, matching the deliberate non-sharing decision the rest
    /// of `PointCloudFloorPlanBuilder` already made against `FloorPlan.swift`.
    private func draw(_ result: PointCloudFloorPlanBuilder.Result, in context: inout GraphicsContext, size: CGSize) {
        // Once a transform exists, everything is drawn in RoomPlan's frame:
        // the reference plan stays put and the point-cloud plan moves onto
        // it, which is the comparison worth looking at (RoomPlan is the
        // familiar frame, and moving it instead would make an unchanged
        // reference look like it had shifted).
        let transform = registration?.transform
        let cloudWalls = result.wallSegments.map { wall -> (start: SIMD2<Float>, end: SIMD2<Float>, isOutOfSquare: Bool) in
            guard let transform else { return (wall.start, wall.end, wall.isOutOfSquare) }
            return (transform.apply(to: wall.start), transform.apply(to: wall.end), wall.isOutOfSquare)
        }
        let cloudPolygons = result.polygons.map { polygon in
            transform.map { polygon.map($0.apply(to:)) } ?? polygon
        }
        let referenceWalls: [(start: SIMD2<Float>, end: SIMD2<Float>)] = (transform == nil ? nil : reference)?
            .walls.map {
                (SIMD2(Float($0.start.x), Float($0.start.y)), SIMD2(Float($0.end.x), Float($0.end.y)))
            } ?? []

        // Framed over both plans, so neither is cropped by fitting only the
        // other one.
        let allPoints = cloudWalls.flatMap { [$0.start, $0.end] } + referenceWalls.flatMap { [$0.start, $0.end] }
        guard !allPoints.isEmpty else { return }

        let minX = allPoints.map(\.x).min() ?? 0
        let maxX = allPoints.map(\.x).max() ?? 0
        let minY = allPoints.map(\.y).min() ?? 0
        let maxY = allPoints.map(\.y).max() ?? 0
        let width = Double(maxX - minX)
        let height = Double(maxY - minY)
        guard width > 0, height > 0 else { return }

        let inset = 24.0
        let scale = min((size.width - inset * 2) / width, (size.height - inset * 2) / height)
        func point(_ p: SIMD2<Float>) -> CGPoint {
            CGPoint(
                x: inset + (Double(p.x) - Double(minX)) * scale,
                y: size.height - inset - (Double(p.y) - Double(minY)) * scale
            )
        }

        // RoomPlan underneath, dashed and faint: the thing being compared
        // against, not the subject of this view.
        for wall in referenceWalls {
            var path = Path()
            path.move(to: point(wall.start))
            path.addLine(to: point(wall.end))
            context.stroke(
                path,
                with: .color(Theme.ink.opacity(0.35)),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 4])
            )
        }

        for polygon in cloudPolygons where polygon.count > 1 {
            var path = Path()
            path.move(to: point(polygon[0]))
            for vertex in polygon.dropFirst() { path.addLine(to: point(vertex)) }
            path.closeSubpath()
            context.fill(path, with: .color(Theme.ink.opacity(0.06)))
        }

        for wall in cloudWalls {
            var path = Path()
            path.move(to: point(wall.start))
            path.addLine(to: point(wall.end))
            context.stroke(
                path,
                with: .color(wall.isOutOfSquare ? .orange : Theme.ink),
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
        }
    }
}
#endif
