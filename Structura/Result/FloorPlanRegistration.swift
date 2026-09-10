import simd

/// Brings a floor plan derived from Pro Scan's own point cloud
/// (`PointCloudFloorPlanBuilder`) into the coordinate frame of the RoomPlan
/// plan (`FloorPlan`), so the two can be compared or overlaid at all.
///
/// # Why this is needed
///
/// Pro Scan runs as a second ARKit session with `.resetTracking`, so its
/// world origin has no relationship to the one RoomPlan used — the two plans
/// describe the same building in two unrelated frames. No amount of work on
/// either plan's own geometry makes them agree; the frames have to be
/// related first. This is the architecture audit's "bloqueo estructural",
/// solved the only way a public API allows: by matching the geometry itself
/// after the fact.
///
/// # What is being solved for
///
/// Only a 2D **rigid** transform — one rotation and one translation:
///
/// - No scale. Both frames are metric and metrically correct; fitting a
///   scale factor would let a drifted scan silently "fix" itself by
///   shrinking, turning a tracking error into a plausible-looking plan.
/// - No reflection. `FloorPlan` and `PointCloudFloorPlanBuilder` both
///   project world (X, Z) to plan (x, y) with the same handedness, so a
///   reflection would never be a legitimate answer.
/// - No vertical component. Both sessions run `worldAlignment = .gravity`,
///   which means the two frames already share a plumb vertical axis and can
///   only differ by yaw — the one rotation this solves for.
///
/// Pure Swift/simd, no ARKit or RoomPlan types (callers convert their own
/// segments into `Segment2D`), so it compiles into the host-less
/// `StructuraTests` target and is tested against synthetic rooms with a
/// known applied transform.
enum FloorPlanRegistration {

    // MARK: - Input and output

    struct Segment2D: Equatable {
        var start: SIMD2<Float>
        var end: SIMD2<Float>

        var lengthMeters: Float { simd_distance(start, end) }
        var midpoint: SIMD2<Float> { (start + end) / 2 }
    }

    struct Transform: Equatable {
        var rotationRadians: Float
        var translation: SIMD2<Float>

        static let identity = Transform(rotationRadians: 0, translation: .zero)

        func apply(to point: SIMD2<Float>) -> SIMD2<Float> {
            let cosine = cos(rotationRadians)
            let sine = sin(rotationRadians)
            return SIMD2(
                cosine * point.x - sine * point.y,
                sine * point.x + cosine * point.y
            ) + translation
        }

        func apply(to segment: Segment2D) -> Segment2D {
            Segment2D(start: apply(to: segment.start), end: apply(to: segment.end))
        }
    }

    struct Result: Equatable {
        var transform: Transform
        /// Median distance, in metres, from a sampled source point to the
        /// nearest target wall after transforming. The honest headline
        /// number: a registration is only as good as this says it is.
        var medianResidualMeters: Float
        /// Fraction of sampled source points that landed within
        /// `inlierDistanceMeters` of some target wall. Low values mean the
        /// two plans mostly don't describe the same surfaces — the transform
        /// may be arbitrary even if the median residual looks acceptable.
        var inlierFraction: Float

        /// Whether this fit is worth *presenting* as an alignment rather than
        /// just reporting as a number.
        ///
        /// Both thresholds are engineering placeholders, not values
        /// calibrated against paired real captures: 20 cm is roughly where a
        /// misalignment stops being explicable by Pro Scan's own drift and
        /// RoomPlan's own wall-position error, and 60% is where enough walls
        /// correspond that the transform is describing the same building
        /// rather than coincidence. Revisit both once real paired scans exist
        /// to measure against.
        var isTrustworthy: Bool {
            medianResidualMeters <= 0.20 && inlierFraction >= 0.6
        }
    }

    // MARK: - Tuning

    /// Spacing of the synthetic samples laid along each source wall. Finer
    /// than the point cloud's own 2 cm fusion grid buys nothing here: this
    /// samples *fitted lines*, not measurements.
    static let sampleSpacingMeters: Float = 0.10

    /// Ceiling on sampled points, so a large multi-room plan can't make the
    /// nearest-neighbour search quadratic-expensive on a phone.
    static let maximumSamples = 2_000

    /// A correspondence further than this is treated as "these two walls are
    /// not the same wall" and excluded from the fit, rather than dragging the
    /// solution toward a wall that only one of the two plans has. An
    /// engineering placeholder chosen against typical room scale, not a value
    /// calibrated against real paired captures.
    static let defaultInlierDistanceMeters: Float = 0.5

    static let refinementIterations = 12

    // MARK: - Entry point

    /// `nil` when there isn't enough geometry on either side to fit anything.
    ///
    /// A non-`nil` result is **not** a claim that the fit is good — read
    /// `medianResidualMeters` and `inlierFraction` and decide. Returning a
    /// transform plus its own error is deliberate: the caller showing an
    /// overlay needs to be able to refuse to draw one.
    static func align(
        _ source: [Segment2D],
        to target: [Segment2D],
        inlierDistanceMeters: Float = defaultInlierDistanceMeters
    ) -> Result? {
        let usableSource = source.filter { $0.lengthMeters > 0 }
        let usableTarget = target.filter { $0.lengthMeters > 0 }
        guard !usableSource.isEmpty, !usableTarget.isEmpty else { return nil }

        let samples = sampledPoints(along: usableSource)
        guard !samples.isEmpty else { return nil }

        // A rectilinear room maps onto itself every 90°, so the dominant
        // directions alone can't tell which of four rotations is the right
        // one. Try all four and let the residual decide, instead of trusting
        // an orientation estimate that is genuinely ambiguous.
        let sourceGrid = dominantOrientation(of: usableSource)
        let targetGrid = dominantOrientation(of: usableTarget)

        var best: Result?
        for quarterTurn in 0..<4 {
            let rotation = targetGrid - sourceGrid + Float(quarterTurn) * .pi / 2
            let seeded = seedTransform(rotating: samples, by: rotation, onto: usableTarget)
            let refined = refine(
                seeded,
                samples: samples,
                target: usableTarget,
                inlierDistanceMeters: inlierDistanceMeters
            )
            let candidate = score(
                refined,
                samples: samples,
                target: usableTarget,
                inlierDistanceMeters: inlierDistanceMeters
            )
            if best == nil || candidate.medianResidualMeters < best!.medianResidualMeters {
                best = candidate
            }
        }
        return best
    }

    // MARK: - Orientation

    /// Length-weighted dominant direction, modulo 90°.
    ///
    /// Angles are quadrupled before averaging so that directions 90° apart
    /// reinforce rather than cancel: the two axes of a rectangular room are
    /// the *same* grid, and a plain circular mean of raw angles would average
    /// them into a meaningless 45°.
    static func dominantOrientation(of segments: [Segment2D]) -> Float {
        var accumulator = SIMD2<Float>.zero
        for segment in segments {
            let delta = segment.end - segment.start
            let length = simd_length(delta)
            guard length > 0 else { continue }
            let angle = atan2(delta.y, delta.x)
            accumulator += length * SIMD2(cos(4 * angle), sin(4 * angle))
        }
        guard accumulator != .zero else { return 0 }
        return atan2(accumulator.y, accumulator.x) / 4
    }

    // MARK: - Sampling

    static func sampledPoints(along segments: [Segment2D]) -> [SIMD2<Float>] {
        let totalLength = segments.reduce(Float(0)) { $0 + $1.lengthMeters }
        guard totalLength > 0 else { return [] }
        // Widen the spacing rather than truncate the plan, so samples stay
        // spread over all of it instead of stopping partway through.
        let spacing = max(sampleSpacingMeters, totalLength / Float(maximumSamples))

        var points: [SIMD2<Float>] = []
        for segment in segments {
            let length = segment.lengthMeters
            let steps = max(1, Int(length / spacing))
            for step in 0...steps {
                let t = Float(step) / Float(steps)
                points.append(segment.start + (segment.end - segment.start) * t)
            }
        }
        return points
    }

    // MARK: - Fitting

    /// Rotation plus the translation that makes the two centroids coincide —
    /// the starting guess `refine` improves on.
    private static func seedTransform(
        rotating samples: [SIMD2<Float>],
        by rotation: Float,
        onto target: [Segment2D]
    ) -> Transform {
        let rotationOnly = Transform(rotationRadians: rotation, translation: .zero)
        let rotatedCentroid = centroid(of: samples.map(rotationOnly.apply(to:)))
        let targetCentroid = centroid(of: target.map(\.midpoint))
        return Transform(rotationRadians: rotation, translation: targetCentroid - rotatedCentroid)
    }

    /// Point-to-segment ICP: repeatedly pair each transformed sample with its
    /// nearest point on the target walls, then re-solve the rigid transform
    /// that best explains those pairs.
    ///
    /// The pairing threshold is **annealed** — wide on the first iteration,
    /// tightening geometrically to `inlierDistanceMeters` by the last. Held
    /// at its final value throughout instead, a seed thrown off by geometry
    /// that only one plan contains (a façade Pro Scan swept and RoomPlan
    /// can't see, say) starts with every sample beyond the threshold, finds
    /// no correspondences at all, and returns that bad seed unrefined. The
    /// wide early passes are what let a rough seed pull itself in before the
    /// threshold gets strict enough to reject genuinely unmatched walls.
    private static func refine(
        _ initial: Transform,
        samples: [SIMD2<Float>],
        target: [Segment2D],
        inlierDistanceMeters: Float
    ) -> Transform {
        // Scaled to the plan itself, so the first pass is generous on a
        // building and still meaningful on a single room.
        let initialThreshold = max(inlierDistanceMeters, boundingDiagonal(of: target))

        var transform = initial
        for iteration in 0..<refinementIterations {
            let progress = Float(iteration) / Float(max(1, refinementIterations - 1))
            let threshold = initialThreshold * pow(inlierDistanceMeters / initialThreshold, progress)

            var sourcePoints: [SIMD2<Float>] = []
            var targetPoints: [SIMD2<Float>] = []
            sourcePoints.reserveCapacity(samples.count)
            targetPoints.reserveCapacity(samples.count)

            for sample in samples {
                let transformed = transform.apply(to: sample)
                guard let match = nearestPoint(to: transformed, on: target),
                      simd_distance(transformed, match) <= threshold else { continue }
                // Paired in the *original* source frame: the solver below
                // computes an absolute transform, not an increment on top of
                // the current one.
                sourcePoints.append(sample)
                targetPoints.append(match)
            }

            // Two pairs is the minimum that constrains a 2D rigid transform.
            guard sourcePoints.count >= 2, let solved = rigidTransform(from: sourcePoints, to: targetPoints) else { break }
            let settled = abs(solved.rotationRadians - transform.rotationRadians) < 1e-6
                && simd_distance(solved.translation, transform.translation) < 1e-6
            transform = solved
            // Only an exit once the threshold has effectively finished
            // tightening: settling under a still-wide threshold says nothing
            // about where the strict-threshold solution lies.
            if settled && progress > 0.9 { break }
        }
        return transform
    }

    /// Closed-form least-squares rigid fit (the 2D case of Kabsch/Umeyama,
    /// with scale fixed at 1 — see this type's doc comment for why scale is
    /// deliberately not estimated).
    static func rigidTransform(from source: [SIMD2<Float>], to target: [SIMD2<Float>]) -> Transform? {
        guard source.count == target.count, source.count >= 2 else { return nil }
        let sourceCentroid = centroid(of: source)
        let targetCentroid = centroid(of: target)

        var crossTerm: Float = 0   // Σ (px·qy − py·qx) — drives sin θ
        var dotTerm: Float = 0     // Σ (px·qx + py·qy) — drives cos θ
        for index in source.indices {
            let p = source[index] - sourceCentroid
            let q = target[index] - targetCentroid
            crossTerm += p.x * q.y - p.y * q.x
            dotTerm += p.x * q.x + p.y * q.y
        }
        // Both terms vanishing means the centered points carry no orientation
        // information at all (every point sits on its own centroid).
        guard crossTerm != 0 || dotTerm != 0 else { return nil }

        let rotation = atan2(crossTerm, dotTerm)
        let rotationOnly = Transform(rotationRadians: rotation, translation: .zero)
        return Transform(
            rotationRadians: rotation,
            translation: targetCentroid - rotationOnly.apply(to: sourceCentroid)
        )
    }

    // MARK: - Scoring

    private static func score(
        _ transform: Transform,
        samples: [SIMD2<Float>],
        target: [Segment2D],
        inlierDistanceMeters: Float
    ) -> Result {
        var residuals: [Float] = []
        residuals.reserveCapacity(samples.count)
        for sample in samples {
            let transformed = transform.apply(to: sample)
            guard let match = nearestPoint(to: transformed, on: target) else { continue }
            residuals.append(simd_distance(transformed, match))
        }
        guard !residuals.isEmpty else {
            return Result(transform: transform, medianResidualMeters: .infinity, inlierFraction: 0)
        }
        let inliers = residuals.filter { $0 <= inlierDistanceMeters }.count
        residuals.sort()
        // Median, not mean: walls that exist in only one of the two plans are
        // expected, and their large residuals must not drag the reported
        // quality of an otherwise good fit.
        return Result(
            transform: transform,
            medianResidualMeters: residuals[residuals.count / 2],
            inlierFraction: Float(inliers) / Float(residuals.count)
        )
    }

    // MARK: - Geometry helpers

    /// Diagonal of the axis-aligned box containing every endpoint — a
    /// single number standing in for "how big is this plan", used to scale
    /// the annealing schedule to the drawing rather than to a fixed metre
    /// value that would be generous for a room and tiny for a building.
    static func boundingDiagonal(of segments: [Segment2D]) -> Float {
        var minimum = SIMD2<Float>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var maximum = SIMD2<Float>(-.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        for segment in segments {
            for point in [segment.start, segment.end] {
                minimum = simd_min(minimum, point)
                maximum = simd_max(maximum, point)
            }
        }
        guard maximum.x >= minimum.x else { return 0 }
        return simd_length(maximum - minimum)
    }

    static func centroid(of points: [SIMD2<Float>]) -> SIMD2<Float> {
        guard !points.isEmpty else { return .zero }
        return points.reduce(.zero, +) / Float(points.count)
    }

    static func closestPoint(to point: SIMD2<Float>, on segment: Segment2D) -> SIMD2<Float> {
        let delta = segment.end - segment.start
        let lengthSquared = simd_length_squared(delta)
        guard lengthSquared > 0 else { return segment.start }
        // Clamped, so a point beyond a wall's end matches that end rather than
        // a projection onto the wall's infinite extension.
        let t = simd_clamp(simd_dot(point - segment.start, delta) / lengthSquared, 0, 1)
        return segment.start + delta * t
    }

    static func nearestPoint(to point: SIMD2<Float>, on segments: [Segment2D]) -> SIMD2<Float>? {
        var best: SIMD2<Float>?
        var bestDistance = Float.infinity
        for segment in segments {
            let candidate = closestPoint(to: point, on: segment)
            let distance = simd_distance_squared(point, candidate)
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return best
    }
}
