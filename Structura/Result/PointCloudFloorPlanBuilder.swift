import Foundation
import simd

/// Derives a 2D wall polygon directly from Pro Scan's own fused point cloud
/// (`ARPointCloudSession.currentMeshPoints`) — Fase 4 of the architecture
/// audit, addressing "el bloqueo estructural": today's floor plan
/// (`FloorPlan.swift`) comes from `RoomPlan`'s `CapturedStructure`, built in
/// an entirely separate `ARSession` with its own coordinate origin. None of
/// ProScan's actual precision work — real per-point confidence, LAS 1.4
/// export, control-point anchoring — reaches the plan the app shows, and
/// RoomPlan itself only understands interior rooms, not the facades,
/// excavations, or structures civil-engineering scans need.
///
/// Pipeline: estimate the floor height from the cloud's own near-horizontal
/// points → take a thin horizontal slice at wall height and keep only its
/// near-vertical-normal (wall-like) points, projected to 2D → RANSAC-detect
/// straight line segments in that 2D point set → snap the detected walls to
/// their dominant grid angle and weld their corners (the same two
/// operations `FloorPlan.swift` already uses for the RoomPlan path, applied
/// here to a plain `SIMD2<Float>` segment model instead of duplicating that
/// type's RoomPlan-specific fields) → chain welded segments into closed
/// polygons.
///
/// # Validation status — read before wiring this into product UI
///
/// Every function below is pure and has synthetic-data tests (clean
/// rectangular rooms, injected noise, multiple rooms). That is deliberately
/// not the same claim as "validated." `PlaneSnapping`'s doc comment already
/// makes this point about a related, smaller piece of this codebase: "a
/// classifier that splits a neighborhood into multiple planes needs
/// thresholds tuned against real, noisy device scans to be trustworthy, and
/// shipping one unvalidated would assert a robustness this code can't
/// actually back up." That is even more true here — floor-height
/// estimation, the wall-candidate height band, and the RANSAC inlier
/// distance are all engineering placeholders (see each one's own doc
/// comment for its specific number and reasoning), not values tuned against
/// a real LiDAR scan of a real, imperfect, furniture-cluttered room. This
/// type is Fase 4's algorithmic core, not a finished, ship-ready
/// replacement for `FloorPlan`/RoomPlan: it needs a pass against real
/// device recordings of several different room shapes/sizes before any UI
/// surfaces its output as *the* plan, exactly as Fase 0 required real
/// profiling before trusting the performance work.
///
/// Pure Swift/simd, no ARKit/RoomPlan dependency (only `PointCloudExportPoint`,
/// itself ARKit-free) — like `ProScanConfig`/`PlaneSnapping` — so it compiles
/// into the host-less `StructuraTests` logic-test target.
enum PointCloudFloorPlanBuilder {

    // MARK: - Result

    struct WallSegment {
        var start: SIMD2<Float>
        var end: SIMD2<Float>
        /// How many 2D points the RANSAC pass attributed to this wall — a
        /// coarse "how well-observed is this wall" signal, analogous to
        /// `FloorPlan.Segment.confidence` on the RoomPlan path, though not
        /// the same quantity (this counts supporting samples, not an ARKit-
        /// reported confidence level).
        var inlierCount: Int
        /// Same meaning as `FloorPlan.Segment.isOutOfSquare`: this wall
        /// deviated from the room's dominant grid angle by more than the
        /// squaring tolerance, so it was left at its detected angle instead
        /// of being snapped.
        var isOutOfSquare = false

        var lengthMeters: Float { simd_distance(start, end) }
    }

    struct Result {
        var wallSegments: [WallSegment]
        /// Closed polygon(s) chained from `wallSegments` by shared endpoints
        /// — more than one for structures with separate, non-adjoining
        /// rooms, matching `FloorPlan.floorPolygons`'s same reasoning.
        var polygons: [[SIMD2<Float>]]
        var floorHeightMeters: Float
        var gridAngleRadians: Float
    }

    // MARK: - Floor height

    /// A point whose normal points mostly straight up or down (dot product
    /// with the vertical axis at or above this magnitude) is a floor,
    /// ceiling, tabletop, or similar horizontal surface — a floor/ceiling
    /// candidate, as opposed to a wall (near-horizontal normal). An
    /// engineering placeholder, not a value tuned against real scans: 0.8
    /// (≈37° of tilt tolerance) is a conservative middle ground between
    /// "strict enough that a slightly-tilted wall isn't mistaken for a
    /// floor" and "loose enough to tolerate real LiDAR normal noise."
    static let verticalNormalDotThreshold: Float = 0.8

    /// Bin width for the floor-height histogram below. 5 cm is finer than
    /// `ProScanConfig.voxelSizeMeters` (2 cm) would require strictly, but
    /// coarse enough that real floor-surface noise (LiDAR depth noise,
    /// slightly uneven flooring) still falls into a shared bin rather than
    /// splitting a real floor across several near-empty ones.
    static let floorHeightBinSizeMeters: Float = 0.05

    /// Estimates the floor's height (world-space Y) from the cloud's own
    /// near-horizontal points, without any RoomPlan input.
    ///
    /// Among points whose normal is near-vertical (`verticalNormalDotThreshold`
    /// — floor/ceiling/tabletop candidates), the floor is the *largest*
    /// cluster of them in the *lower* half of the observed height range —
    /// not simply the single lowest point (a single stray low-noise sample
    /// would otherwise be mistaken for the floor) and not simply the
    /// largest cluster overall (a large tabletop or a ceiling with more
    /// total coverage than the floor would win instead). Returns `nil` if
    /// there are no near-horizontal points at all — nothing to estimate
    /// from, not a floor at height zero.
    static func estimateFloorHeight(positions: [SIMD3<Float>], normals: [SIMD3<Float>]) -> Float? {
        precondition(positions.count == normals.count, "positions and normals must be parallel arrays.")

        var horizontalHeights: [Float] = []
        horizontalHeights.reserveCapacity(positions.count)
        for index in positions.indices {
            let normal = normals[index]
            let normalLength = simd_length(normal)
            guard normalLength > 0 else { continue }
            if abs(normal.y / normalLength) >= verticalNormalDotThreshold {
                horizontalHeights.append(positions[index].y)
            }
        }
        guard let minHeight = horizontalHeights.min(), let maxHeight = horizontalHeights.max() else { return nil }
        guard maxHeight > minHeight else { return minHeight }

        var binCounts: [Int: Int] = [:]
        for height in horizontalHeights {
            let bin = Int(((height - minHeight) / floorHeightBinSizeMeters).rounded(.down))
            binCounts[bin, default: 0] += 1
        }

        let midHeight = (minHeight + maxHeight) / 2
        let lowerHalfBins = binCounts.filter { bin, _ in
            minHeight + Float(bin) * floorHeightBinSizeMeters <= midHeight
        }
        // Falls back to every bin only if the lower half is somehow empty
        // (e.g. every horizontal point is exactly at the midpoint) — a
        // degenerate case that should still return *some* answer rather
        // than `nil`.
        let candidateBins = lowerHalfBins.isEmpty ? binCounts : lowerHalfBins
        guard let bestBin = candidateBins.max(by: { $0.value < $1.value })?.key else { return nil }
        return minHeight + (Float(bestBin) + 0.5) * floorHeightBinSizeMeters
    }

    // MARK: - Wall-candidate slice

    /// Extracts the points that look like wall surface within a thin
    /// horizontal band, projected to the 2D (X, Z) ground plane.
    ///
    /// - Parameters:
    ///   - sliceHeightAboveFloor: how far above the estimated floor to take
    ///     the slice. 1.0 m is an engineering placeholder chosen to clear
    ///     most furniture (which rarely reaches a full meter of height
    ///     across its whole footprint) while staying well below a typical
    ///     ~2.4 m ceiling — not a value derived from a real furnished-room
    ///     scan.
    ///   - sliceThickness: total vertical extent of the band. Wide enough
    ///     (15 cm) to gather enough LiDAR samples at typical scan coverage
    ///     to support RANSAC line fitting, narrow enough to stay a genuine
    ///     "slice" rather than smearing in points from well above or below
    ///     the intended height.
    ///   - maxVerticalNormalDot: the complement of `verticalNormalDotThreshold`
    ///     above — a wall-candidate point's normal must point mostly
    ///     *sideways*, not up/down, which is what actually distinguishes a
    ///     wall sample from a piece of furniture's horizontal top surface
    ///     that happens to fall within the height band.
    static func wallCandidatePoints2D(
        positions: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        floorHeight: Float,
        sliceHeightAboveFloor: Float = 1.0,
        sliceThickness: Float = 0.15,
        maxVerticalNormalDot: Float = 0.3
    ) -> [SIMD2<Float>] {
        precondition(positions.count == normals.count, "positions and normals must be parallel arrays.")

        let sliceCenter = floorHeight + sliceHeightAboveFloor
        let halfThickness = sliceThickness / 2
        var result: [SIMD2<Float>] = []
        for index in positions.indices {
            let position = positions[index]
            guard abs(position.y - sliceCenter) <= halfThickness else { continue }
            let normal = normals[index]
            let normalLength = simd_length(normal)
            guard normalLength > 0, abs(normal.y / normalLength) <= maxVerticalNormalDot else { continue }
            result.append(SIMD2<Float>(position.x, position.z))
        }
        return result
    }

    // MARK: - RANSAC line detection

    /// A minimal, seedable `RandomNumberGenerator` (SplitMix64 — Vigna's
    /// public-domain algorithm) so `detectWallLines` is deterministic for
    /// tests. `SystemRandomNumberGenerator` cannot be seeded, which would
    /// make RANSAC's own tests flaky by construction.
    struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    struct DetectedLine {
        var start: SIMD2<Float>
        var end: SIMD2<Float>
        var inlierCount: Int
    }

    /// Repeatedly extracts the best-supported straight line from `points`
    /// via RANSAC, removes its inliers, and repeats — the standard
    /// "sequential RANSAC" approach to detecting multiple lines in one
    /// point set, rather than a single global fit.
    ///
    /// - Parameters:
    ///   - inlierDistanceThreshold: how far (meters) a point may sit from a
    ///     candidate line and still count as support for it. An engineering
    ///     placeholder — needs to be wide enough to tolerate real LiDAR
    ///     noise at `sliceThickness`-band scale, narrow enough that two
    ///     genuinely different walls don't get merged into one line.
    ///   - minimumInliers: a candidate line with fewer supporting points
    ///     than this is discarded rather than accepted as a real wall — the
    ///     same "don't fabricate a fit" principle `PlaneSnapping` already
    ///     applies for its own minimum-neighbor requirement.
    ///   - iterationsPerLine: RANSAC hypothesis count per extracted line.
    ///   - maxLines: a hard ceiling so a pathological input (e.g. dense,
    ///     uniform noise with no real structure) can't loop indefinitely.
    static func detectWallLines(
        points: [SIMD2<Float>],
        inlierDistanceThreshold: Float = 0.03,
        minimumInliers: Int = 20,
        iterationsPerLine: Int = 500,
        maxLines: Int = 64,
        generator: inout SeededGenerator
    ) -> [DetectedLine] {
        var remaining = points
        var lines: [DetectedLine] = []

        while remaining.count >= minimumInliers, lines.count < maxLines {
            guard let (line, inlierIndices) = fitBestLineRANSAC(
                points: remaining,
                distanceThreshold: inlierDistanceThreshold,
                iterations: iterationsPerLine,
                generator: &generator
            ), inlierIndices.count >= minimumInliers else {
                break
            }

            lines.append(line)
            for index in inlierIndices.sorted(by: >) {
                remaining.remove(at: index)
            }
        }
        return lines
    }

    /// One RANSAC pass: repeatedly hypothesizes a line from two random
    /// points, scores it by inlier count, keeps the best-scoring hypothesis,
    /// then refits that winning line by total-least-squares over its own
    /// inliers (a more stable direction estimate than the original two-point
    /// sample) and recomputes the final inlier set and segment extent
    /// against the refined line.
    private static func fitBestLineRANSAC(
        points: [SIMD2<Float>],
        distanceThreshold: Float,
        iterations: Int,
        generator: inout SeededGenerator
    ) -> (DetectedLine, [Int])? {
        guard points.count >= 2 else { return nil }

        var bestInlierIndices: [Int] = []
        for _ in 0..<iterations {
            let i = Int.random(in: 0..<points.count, using: &generator)
            var j = Int.random(in: 0..<points.count, using: &generator)
            if j == i { j = (i + 1) % points.count }

            let p1 = points[i], p2 = points[j]
            let direction = p2 - p1
            let length = simd_length(direction)
            guard length > 1e-6 else { continue }
            let unitDirection = direction / length

            var inlierIndices: [Int] = []
            inlierIndices.reserveCapacity(points.count)
            for (index, point) in points.enumerated() {
                let toPoint = point - p1
                // Perpendicular distance from `point` to the line through
                // `p1`/`p2`: the magnitude of the 2D "cross product" between
                // the offset and the line's unit direction.
                let distance = abs(toPoint.x * unitDirection.y - toPoint.y * unitDirection.x)
                if distance <= distanceThreshold {
                    inlierIndices.append(index)
                }
            }
            if inlierIndices.count > bestInlierIndices.count {
                bestInlierIndices = inlierIndices
            }
        }

        guard !bestInlierIndices.isEmpty else { return nil }

        let inlierPoints = bestInlierIndices.map { points[$0] }
        guard let (centroid, direction) = fitLineTotalLeastSquares(to: inlierPoints) else { return nil }

        // Recompute the final inlier set against the *refined* line, not
        // the original two-point hypothesis — a point just outside the
        // rough hypothesis' threshold can legitimately belong to the
        // refined, more accurate line, and vice versa.
        var refinedInlierIndices: [Int] = []
        refinedInlierIndices.reserveCapacity(points.count)
        var minProjection = Float.greatestFiniteMagnitude
        var maxProjection = -Float.greatestFiniteMagnitude
        for (index, point) in points.enumerated() {
            let toPoint = point - centroid
            let distance = abs(toPoint.x * direction.y - toPoint.y * direction.x)
            guard distance <= distanceThreshold else { continue }
            refinedInlierIndices.append(index)
            let projection = simd_dot(toPoint, direction)
            minProjection = min(minProjection, projection)
            maxProjection = max(maxProjection, projection)
        }
        guard !refinedInlierIndices.isEmpty, minProjection.isFinite, maxProjection.isFinite else { return nil }

        let start = centroid + direction * minProjection
        let end = centroid + direction * maxProjection
        return (DetectedLine(start: start, end: end, inlierCount: refinedInlierIndices.count), refinedInlierIndices)
    }

    /// Orthogonal-regression ("total least squares") line fit: the
    /// direction is the principal axis of the points' 2D covariance matrix,
    /// computed in closed form rather than via a general eigendecomposition
    /// — the standard formula for the dominant eigenvector angle of a
    /// symmetric 2x2 matrix. More robust to points scattered on both sides
    /// of a near-vertical line than an ordinary least-squares "y as a
    /// function of x" fit, which breaks down entirely for a perfectly
    /// vertical line.
    private static func fitLineTotalLeastSquares(to points: [SIMD2<Float>]) -> (centroid: SIMD2<Float>, direction: SIMD2<Float>)? {
        guard !points.isEmpty else { return nil }
        let centroid = points.reduce(SIMD2<Float>.zero, +) / Float(points.count)
        var covXX: Float = 0, covYY: Float = 0, covXY: Float = 0
        for point in points {
            let d = point - centroid
            covXX += d.x * d.x
            covYY += d.y * d.y
            covXY += d.x * d.y
        }
        // All points coincide — no direction to speak of.
        guard covXX != 0 || covYY != 0 || covXY != 0 else { return nil }
        let angle = 0.5 * atan2(2 * covXY, covXX - covYY)
        return (centroid, SIMD2<Float>(cos(angle), sin(angle)))
    }

    // MARK: - Squaring (shared reasoning with FloorPlan.dominantGridAngle/snap)

    /// Length-weighted circular mean of the wall angles, folded into a
    /// single 90° period so all four cardinal directions reinforce one
    /// estimate — the same approach `FloorPlan.dominantGridAngle` uses for
    /// the RoomPlan path, reimplemented here for `WallSegment`/`SIMD2<Float>`
    /// rather than sharing code with that RoomPlan-specific type, to keep
    /// this Fase 4 addition from touching the already-shipping RoomPlan
    /// path at all. Worth unifying later (Fase 5) once this path has real-
    /// device validation of its own.
    static func dominantGridAngle(of segments: [WallSegment]) -> Float {
        var sumCos: Float = 0, sumSin: Float = 0
        for segment in segments {
            let length = segment.lengthMeters
            let angle = atan2(segment.end.y - segment.start.y, segment.end.x - segment.start.x)
            let folded = 4 * angle
            sumCos += cos(folded) * length
            sumSin += sin(folded) * length
        }
        guard sumCos != 0 || sumSin != 0 else { return 0 }
        return atan2(sumSin, sumCos) / 4
    }

    /// Snaps each segment to the nearest multiple-of-90°-from-`grid` angle,
    /// about its own midpoint, if within `toleranceRadians`; otherwise flags
    /// `isOutOfSquare` and leaves it at its detected angle. Mirrors
    /// `FloorPlan.snap`'s behavior exactly, retyped for `WallSegment`.
    static func snapToGrid(_ segments: inout [WallSegment], grid: Float, toleranceRadians: Float) {
        for index in segments.indices {
            let segment = segments[index]
            let angle = atan2(segment.end.y - segment.start.y, segment.end.x - segment.start.x)
            let steps = ((angle - grid) / (.pi / 2)).rounded()
            let target = grid + steps * (.pi / 2)
            if abs(angle - target) <= toleranceRadians {
                let length = segment.lengthMeters
                let center = (segment.start + segment.end) / 2
                let half = length / 2
                let direction = SIMD2<Float>(cos(target), sin(target))
                segments[index].start = center - direction * half
                segments[index].end = center + direction * half
            } else {
                segments[index].isOutOfSquare = true
            }
        }
    }

    /// After independent snapping, corners no longer meet — pulls each
    /// endpoint onto its intersection with the nearest neighboring endpoint,
    /// mirroring `FloorPlan.weldCorners` (same threshold, same "each
    /// endpoint picks its own nearest match across all others" reasoning;
    /// see that method's doc comment for why a plain fixed cutoff isn't
    /// enough at oblique joints).
    static func weldCorners(_ segments: inout [WallSegment], thresholdMeters: Float = 0.6) {
        guard segments.count > 1 else { return }

        for a in segments.indices {
            for isEndOfA in [false, true] {
                let pointA = isEndOfA ? segments[a].end : segments[a].start
                var bestDistance = thresholdMeters
                var bestCorner: SIMD2<Float>?
                var bestB = -1
                var bestIsEndOfB = false

                for b in segments.indices where b != a {
                    for isEndOfB in [false, true] {
                        let pointB = isEndOfB ? segments[b].end : segments[b].start
                        let distance = simd_distance(pointA, pointB)
                        guard distance < bestDistance,
                              let corner = intersection(of: segments[a], and: segments[b]),
                              simd_distance(corner, pointA) <= thresholdMeters * 2
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

    private static func intersection(of first: WallSegment, and second: WallSegment) -> SIMD2<Float>? {
        let direction = first.end - first.start
        let otherDirection = second.end - second.start
        let denominator = direction.x * otherDirection.y - direction.y * otherDirection.x
        guard abs(denominator) > 1e-6 else { return nil }

        let t = ((second.start.x - first.start.x) * otherDirection.y
            - (second.start.y - first.start.y) * otherDirection.x) / denominator
        return first.start + direction * t
    }

    // MARK: - Polygon closure

    /// Chains welded segments into closed polygon(s) by shared endpoints,
    /// rather than assuming `segments` is already in perimeter order —
    /// mirrors `FloorPlan.floorPolygons`'s identical reasoning, including
    /// returning more than one polygon for separate, non-adjoining rooms.
    static func closePolygons(from segments: [WallSegment], toleranceMeters: Float = 0.5) -> [[SIMD2<Float>]] {
        var remaining = segments
        var polygons: [[SIMD2<Float>]] = []

        while !remaining.isEmpty {
            let first = remaining.removeFirst()
            var polygon: [SIMD2<Float>] = [first.start, first.end]
            var cursor = first.end

            while let matchIndex = remaining.firstIndex(where: {
                simd_distance($0.start, cursor) <= toleranceMeters || simd_distance($0.end, cursor) <= toleranceMeters
            }) {
                let segment = remaining.remove(at: matchIndex)
                let startsAtCursor = simd_distance(segment.start, cursor) <= toleranceMeters
                let nextPoint = startsAtCursor ? segment.end : segment.start
                polygon.append(nextPoint)
                cursor = nextPoint
            }

            if polygon.count >= 3 {
                polygons.append(polygon)
            }
        }
        return polygons
    }

    // MARK: - Orchestration

    /// Runs the full pipeline end to end: floor height → wall-candidate
    /// slice → RANSAC line detection → squaring → corner welding → polygon
    /// closure. `nil` if the floor height can't be estimated at all (an
    /// empty or all-zero-normal cloud) — every other stage degrades to an
    /// empty result rather than `nil`, since "no walls detected" is a
    /// meaningful (if useless) answer, unlike "no floor at all."
    static func build(
        from points: [PointCloudExportPoint],
        sliceHeightAboveFloorMeters: Float = 1.0,
        sliceThicknessMeters: Float = 0.15,
        ransacInlierDistanceMeters: Float = 0.03,
        ransacMinimumInliers: Int = 20,
        ransacIterationsPerLine: Int = 500,
        squareToleranceRadians: Float = 5 * .pi / 180,
        weldThresholdMeters: Float = 0.6,
        randomSeed: UInt64 = 0x5EED
    ) -> Result? {
        let positions = points.map(\.position)
        let normals = points.map(\.normal)
        guard let floorHeight = estimateFloorHeight(positions: positions, normals: normals) else { return nil }

        let wallPoints = wallCandidatePoints2D(
            positions: positions, normals: normals, floorHeight: floorHeight,
            sliceHeightAboveFloor: sliceHeightAboveFloorMeters, sliceThickness: sliceThicknessMeters
        )

        var generator = SeededGenerator(seed: randomSeed)
        let lines = detectWallLines(
            points: wallPoints,
            inlierDistanceThreshold: ransacInlierDistanceMeters,
            minimumInliers: ransacMinimumInliers,
            iterationsPerLine: ransacIterationsPerLine,
            generator: &generator
        )

        var segments = lines.map { WallSegment(start: $0.start, end: $0.end, inlierCount: $0.inlierCount) }
        let grid = dominantGridAngle(of: segments)
        snapToGrid(&segments, grid: grid, toleranceRadians: squareToleranceRadians)
        weldCorners(&segments, thresholdMeters: weldThresholdMeters)
        let polygons = closePolygons(from: segments)

        return Result(wallSegments: segments, polygons: polygons, floorHeightMeters: floorHeight, gridAngleRadians: grid)
    }
}
