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

    @State private var result: PointCloudFloorPlanBuilder.Result?
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
                Text("\(result.wallSegments.count) paredes · \(result.polygons.count) polígono(s) · \(pointCount) puntos")
                    .font(.caption2)
                    .foregroundStyle(Theme.ink.opacity(0.5))
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
        let url = plyURL
        let (builtResult, count): (PointCloudFloorPlanBuilder.Result?, Int?) = await Task.detached(priority: .userInitiated) {
            guard let points = PLYPointCloudReader.read(from: url) else { return (nil, nil) }
            return (PointCloudFloorPlanBuilder.build(from: points), points.count)
        }.value
        result = builtResult
        pointCount = count
        didAttemptLoad = true
    }

    /// Minimal top-down rendering — not shared with `FloorPlanView`'s
    /// drawing code, matching the deliberate non-sharing decision the rest
    /// of `PointCloudFloorPlanBuilder` already made against `FloorPlan.swift`.
    private func draw(_ result: PointCloudFloorPlanBuilder.Result, in context: inout GraphicsContext, size: CGSize) {
        let allPoints = result.wallSegments.flatMap { [$0.start, $0.end] }
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

        for polygon in result.polygons where polygon.count > 1 {
            var path = Path()
            path.move(to: point(polygon[0]))
            for vertex in polygon.dropFirst() { path.addLine(to: point(vertex)) }
            path.closeSubpath()
            context.fill(path, with: .color(Theme.ink.opacity(0.06)))
        }

        for segment in result.wallSegments {
            var path = Path()
            path.move(to: point(segment.start))
            path.addLine(to: point(segment.end))
            context.stroke(
                path,
                with: .color(segment.isOutOfSquare ? .orange : Theme.ink),
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
        }
    }
}
#endif
