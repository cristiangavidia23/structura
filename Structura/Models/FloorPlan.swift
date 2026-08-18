import Foundation
import CoreGraphics
import simd
import RoomPlan

/// Top-down projection of a `CapturedRoom`, with a squaring pass that corrects
/// scan noise without hiding genuinely out-of-square geometry.
///
/// Heights are kept alongside the 2D footprint so the same model can drive both
/// the dollhouse and the flattened plan.
struct FloorPlan {
    struct Segment: Identifiable {
        let id: UUID
        let category: Category
        var start: CGPoint
        var end: CGPoint
        /// Distance from the floor to the bottom of the surface. Non-zero for windows.
        var baseHeightMeters: Double
        let heightMeters: Double
        let confidence: CapturedRoom.Confidence
        /// True when RoomPlan never observed both ends of the surface, so its
        /// length is inferred rather than measured.
        let isExtrapolated: Bool
        /// True when the surface deviated from the room's grid by more than the
        /// squaring tolerance, i.e. it was left at its measured angle.
        var isOutOfSquare = false

        enum Category {
            case wall, door, window, opening
        }

        var lengthMeters: Double {
            hypot(end.x - start.x, end.y - start.y)
        }

        var midpoint: CGPoint {
            CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        }

        var angle: Double {
            atan2(end.y - start.y, end.x - start.x)
        }

        /// Whether the *length* shown for this segment was actually measured, as
        /// opposed to inferred because RoomPlan never saw both ends. This is what
        /// drives the "~" prefix and dashed styling.
        ///
        /// Deliberately independent of `confidence`: RoomPlan reports `.high`
        /// rarely even on good scans, so gating on it flagged nearly everything
        /// as unreliable regardless of actual scan quality.
        var isReliable: Bool {
            !isExtrapolated
        }

        /// Raw RoomPlan confidence, for display as its own data point (CSV,
        /// measurement detail) — not folded into `isReliable`.
        var confidenceLabel: String {
            switch confidence {
            case .high: return "alta"
            case .medium: return "media"
            case .low: return "baja"
            @unknown default: return "media"
            }
        }

        mutating func rotate(to newAngle: Double) {
            let half = lengthMeters / 2
            let center = midpoint
            let dx = cos(newAngle) * half
            let dy = sin(newAngle) * half
            start = CGPoint(x: center.x - dx, y: center.y - dy)
            end = CGPoint(x: center.x + dx, y: center.y + dy)
        }
    }

    /// A detected object, reduced to the footprint and height needed to render it
    /// as a block in the dollhouse.
    struct Furniture: Identifiable {
        let id: UUID
        var footprint: [CGPoint]
        var baseHeightMeters: Double
        let heightMeters: Double
    }

    let segments: [Segment]
    let furniture: [Furniture]
    let bounds: CGRect
    let floorAreaSquareMeters: Double
    let wallHeightMeters: Double

    var walls: [Segment] { segments.filter { $0.category == .wall } }
    var doors: [Segment] { segments.filter { $0.category == .door } }
    var windows: [Segment] { segments.filter { $0.category == .window } }
    var openings: [Segment] { segments.filter { $0.category == .opening } }
    var outOfSquareWalls: [Segment] { walls.filter(\.isOutOfSquare) }
    var unreliableWalls: [Segment] { walls.filter { !$0.isReliable } }

    var perimeterMeters: Double {
        walls.reduce(0) { $0 + $1.lengthMeters }
    }

    var volumeCubicMeters: Double {
        floorAreaSquareMeters * wallHeightMeters
    }

    /// - Parameter squareTolerance: Maximum angular error attributed to scan
    ///   noise. Walls within this of the room's grid are snapped; anything
    ///   beyond it is treated as a real out-of-square condition and preserved.
    /// Segments shorter than this are scan artifacts (duplicate corners, stray
    /// slivers from re-passing the same spot), not real geometry — RoomPlan
    /// occasionally emits them, and a zero-length "wall" would otherwise corrupt
    /// the grid-angle estimate and show up as a bogus 0.00 m entry.
    private static let minimumSegmentLength = 0.05

    init(room: CapturedRoom, squareTolerance: Double = 5 * .pi / 180) {
        var collected = Self.makeSegments(from: room)
            .filter { $0.lengthMeters >= Self.minimumSegmentLength }
        var objects = Self.makeFurniture(from: room)

        let grid = Self.dominantGridAngle(of: collected.filter { $0.category == .wall })
        Self.snap(&collected, toGrid: grid, tolerance: squareTolerance)
        Self.weldCorners(&collected)
        // The room's own grid is arbitrarily rotated relative to world axes;
        // cancel it so the plan reads upright instead of tilted on screen.
        Self.rotate(&collected, by: -grid)
        Self.rotate(&objects, by: -grid)

        // RoomPlan reports heights in world space, where the floor sits at an
        // arbitrary level. Rebase everything so the floor is zero.
        let floorLevel = collected.filter { $0.category == .wall }
            .map(\.baseHeightMeters).min() ?? 0
        for index in collected.indices {
            collected[index].baseHeightMeters -= floorLevel
        }
        for index in objects.indices {
            objects[index].baseHeightMeters -= floorLevel
        }

        segments = collected
        furniture = objects

        let points = collected.flatMap { [$0.start, $0.end] }
        if points.isEmpty {
            bounds = .zero
        } else {
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            let minX = xs.min() ?? 0
            let maxX = xs.max() ?? 0
            let minY = ys.min() ?? 0
            let maxY = ys.max() ?? 0
            bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        floorAreaSquareMeters = room.floors.reduce(0) { total, floor in
            total + Double(floor.dimensions.x) * Double(floor.dimensions.y)
        }
        wallHeightMeters = room.walls.map { Double($0.dimensions.y) }.max() ?? 0
    }

    // MARK: - Construction

    private static func makeSegments(from room: CapturedRoom) -> [Segment] {
        var collected: [Segment] = []

        func append(_ surfaces: [CapturedRoom.Surface], category: Segment.Category) {
            for surface in surfaces {
                let halfWidth = surface.dimensions.x / 2
                // RoomPlan surfaces are centered on their transform, extending along local X.
                let worldStart = surface.transform * simd_float4(-halfWidth, 0, 0, 1)
                let worldEnd = surface.transform * simd_float4(halfWidth, 0, 0, 1)
                let height = Double(surface.dimensions.y)
                let centerY = Double(surface.transform.columns.3.y)
                // A surface whose side edges were never fully observed has an
                // inferred width, so its length should not be presented as measured.
                let observedBothEnds = surface.completedEdges.contains(.left)
                    && surface.completedEdges.contains(.right)
                collected.append(
                    Segment(
                        id: surface.identifier,
                        category: category,
                        start: CGPoint(x: Double(worldStart.x), y: Double(worldStart.z)),
                        end: CGPoint(x: Double(worldEnd.x), y: Double(worldEnd.z)),
                        baseHeightMeters: centerY - height / 2,
                        heightMeters: height,
                        confidence: surface.confidence,
                        isExtrapolated: !observedBothEnds
                    )
                )
            }
        }

        append(room.walls, category: .wall)
        append(room.doors, category: .door)
        append(room.windows, category: .window)
        append(room.openings, category: .opening)
        return collected
    }

    private static func makeFurniture(from room: CapturedRoom) -> [Furniture] {
        room.objects.map { object in
            let halfX = object.dimensions.x / 2
            let halfZ = object.dimensions.z / 2
            let localCorners: [simd_float4] = [
                simd_float4(-halfX, 0, -halfZ, 1),
                simd_float4(halfX, 0, -halfZ, 1),
                simd_float4(halfX, 0, halfZ, 1),
                simd_float4(-halfX, 0, halfZ, 1)
            ]
            let height = Double(object.dimensions.y)
            return Furniture(
                id: object.identifier,
                footprint: localCorners.map { corner in
                    let world = object.transform * corner
                    return CGPoint(x: Double(world.x), y: Double(world.z))
                },
                baseHeightMeters: Double(object.transform.columns.3.y) - height / 2,
                heightMeters: height
            )
        }
    }

    // MARK: - Squaring

    /// Length-weighted circular mean of the wall angles, folded into a single
    /// 90° period so all four cardinal directions reinforce one estimate.
    /// Longer walls dominate, which is what we want — they are the better measured ones.
    private static func dominantGridAngle(of walls: [Segment]) -> Double {
        var sumCos = 0.0
        var sumSin = 0.0
        for wall in walls {
            let folded = 4 * wall.angle
            sumCos += cos(folded) * wall.lengthMeters
            sumSin += sin(folded) * wall.lengthMeters
        }
        guard sumCos != 0 || sumSin != 0 else { return 0 }
        return atan2(sumSin, sumCos) / 4
    }

    private static func snap(_ segments: inout [Segment], toGrid grid: Double, tolerance: Double) {
        for index in segments.indices {
            let angle = segments[index].angle
            let steps = ((angle - grid) / (.pi / 2)).rounded()
            let target = grid + steps * (.pi / 2)
            if abs(angle - target) <= tolerance {
                segments[index].rotate(to: target)
            } else {
                segments[index].isOutOfSquare = true
            }
        }
    }

    /// After rotating walls independently their corners no longer meet, so pull
    /// each endpoint onto the intersection with its nearest neighboring endpoint.
    ///
    /// Each endpoint picks its own nearest match across *all* other wall endpoints,
    /// rather than only welding pairs already closer than a small fixed cutoff.
    /// Oblique joints — a wall meeting its neighbors at a non-square angle — tend
    /// to have more scan noise right at the corner than a plain 90° joint, so a
    /// tight absolute threshold left those gaps unwelded.
    private static func weldCorners(_ segments: inout [Segment], threshold: Double = 0.6) {
        let wallIndices = segments.indices.filter { segments[$0].category == .wall }
        guard wallIndices.count > 1 else { return }

        for a in wallIndices {
            for isEndOfA in [false, true] {
                let pointA = isEndOfA ? segments[a].end : segments[a].start
                var bestDistance = threshold
                var bestCorner: CGPoint?
                var bestB = -1
                var bestIsEndOfB = false

                for b in wallIndices where b != a {
                    for isEndOfB in [false, true] {
                        let pointB = isEndOfB ? segments[b].end : segments[b].start
                        let distance = hypot(pointA.x - pointB.x, pointA.y - pointB.y)
                        guard distance < bestDistance,
                              let corner = intersection(of: segments[a], and: segments[b]),
                              // Near-parallel walls intersect far away; that is not a corner.
                              hypot(corner.x - pointA.x, corner.y - pointA.y) <= threshold * 2
                        else { continue }
                        bestDistance = distance
                        bestCorner = corner
                        bestB = b
                        bestIsEndOfB = isEndOfB
                    }
                }

                guard let corner = bestCorner else { continue }
                if isEndOfA { segments[a].end = corner } else { segments[a].start = corner }
                if bestIsEndOfB { segments[bestB].end = corner } else { segments[bestB].start = corner }
            }
        }
    }

    // MARK: - Transforms

    /// Rigid rotation about the origin — lengths and relative angles are preserved,
    /// so every measurement stays valid.
    private static func rotate(_ segments: inout [Segment], by angle: Double) {
        let transform = Rotation(angle: angle)
        for index in segments.indices {
            segments[index].start = transform.apply(segments[index].start)
            segments[index].end = transform.apply(segments[index].end)
        }
    }

    private static func rotate(_ furniture: inout [Furniture], by angle: Double) {
        let transform = Rotation(angle: angle)
        for index in furniture.indices {
            furniture[index].footprint = furniture[index].footprint.map(transform.apply)
        }
    }

    private struct Rotation {
        let cosine: Double
        let sine: Double

        init(angle: Double) {
            cosine = cos(angle)
            sine = sin(angle)
        }

        func apply(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: point.x * cosine - point.y * sine,
                y: point.x * sine + point.y * cosine
            )
        }
    }

    private static func intersection(of first: Segment, and second: Segment) -> CGPoint? {
        let origin = first.start
        let direction = CGPoint(x: first.end.x - first.start.x, y: first.end.y - first.start.y)
        let otherOrigin = second.start
        let otherDirection = CGPoint(x: second.end.x - second.start.x, y: second.end.y - second.start.y)

        let denominator = direction.x * otherDirection.y - direction.y * otherDirection.x
        guard abs(denominator) > 1e-6 else { return nil }

        let t = ((otherOrigin.x - origin.x) * otherDirection.y
            - (otherOrigin.y - origin.y) * otherDirection.x) / denominator
        return CGPoint(x: origin.x + t * direction.x, y: origin.y + t * direction.y)
    }
}
