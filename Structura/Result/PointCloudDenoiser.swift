import simd

/// Thins the scatter that makes a measured flat surface render as a fuzzy
/// slab instead of a plane.
///
/// # The problem
///
/// LiDAR depth carries noise along the view ray, growing with range — at a
/// few metres it is comfortably a couple of centimetres. A wall measured
/// over a whole scan therefore comes back as a *volume* of points several
/// centimetres thick rather than a surface, which is what makes a dense
/// cloud read as cotton wool. Voxel fusion does not fix it: fusion averages
/// samples that land in the *same* 2 cm cell, while this scatter spreads
/// across many cells along the surface normal.
///
/// # What this does about it
///
/// For each point, fit a plane to the neighbours around it and project the
/// point onto that plane — but only where the neighbourhood is convincingly
/// planar. This is the same bargain `PlaneSnapping` already makes for
/// tap-to-measure in this project: a set of samples of one flat surface is
/// better described by the plane through them than by any one noisy member,
/// *and* that reasoning has to be abandoned the moment the data stops
/// looking like a plane.
///
/// The guards are what keep this denoising rather than invention:
///
/// - A neighbourhood that is not clearly planar (a corner, an edge, foliage,
///   clutter, a curved object) is left completely untouched. Real shape is
///   never flattened into a surface that was not there.
/// - A correction larger than `maximumCorrectionMeters` is refused outright.
///   If the fitted plane wants to move a point several centimetres, the
///   point is not noise around that plane — it is something else, and moving
///   it would relocate real geometry.
/// - Isolated points with almost no neighbours are *removed*, not moved:
///   they are the stray fliers depth sensors produce at edges, and there is
///   no surface for them to be projected onto.
///
/// Pure Swift/simd with no ARKit dependency, so it compiles into the
/// host-less test target and is verified against synthetic surfaces whose
/// correct answer is known analytically.
enum PointCloudDenoiser {

    struct Options {
        /// Radius of the neighbourhood each point's plane is fitted to.
        ///
        /// Has to be **several times the sensor noise**, not merely larger
        /// than it. Fitting a plane to points whose scatter is a sizeable
        /// fraction of the neighbourhood's own width is ill-conditioned: the
        /// fit tilts to chase the noise, and projecting onto a tilted plane
        /// re-introduces at the edges roughly what it removed in the middle.
        /// Measured on a synthetic wall, a 6 cm radius against 2 cm noise
        /// tilted the fitted normal by ~11°; 10 cm brings that to ~1°.
        ///
        /// The ceiling on this is architectural rather than numerical: a
        /// radius wide enough to span a whole corner would try to describe
        /// two walls with one plane. The flatness guards below reject that
        /// case, so the cost of being slightly too wide is points left
        /// untouched, not geometry destroyed.
        var neighborhoodRadiusMeters: Float = 0.10

        /// Below this many neighbours a point has no surface around it to
        /// be part of; it is dropped as an isolated flier.
        var minimumNeighbors: Int = 5

        /// How thick a neighbourhood may be, along its own normal, and still
        /// be treated as a noisy plane rather than as structure — the
        /// standard deviation of the points' distance from the fitted plane.
        ///
        /// Stated as an absolute distance on purpose. The obvious
        /// alternative, the *share* of total variance lying along the
        /// normal, sounds scale-free but is not: it depends on how wide the
        /// neighbourhood is, so the same wall passes or fails depending on
        /// the search radius. Asking "is the spread along the normal the
        /// size of sensor noise?" is the question actually being asked, and
        /// its answer does not move when the radius does.
        ///
        /// 2.5 cm is chosen against LiDAR depth noise at room distances. An
        /// engineering placeholder: it has not been calibrated against a
        /// measured noise-versus-range curve for this sensor.
        var maximumSurfaceThicknessMeters: Float = 0.025

        /// How much flatter than its widest spread a neighbourhood must be
        /// to count as a surface at all, as the ratio of the variance along
        /// the normal to the variance along the *second*-least-spread axis.
        ///
        /// Thickness alone is not enough: a small, tight blob of points is
        /// thin in every direction and would pass. This asks the separate
        /// question of whether the points are meaningfully flatter one way
        /// than the others — i.e. whether a plane is the right description
        /// of them rather than merely a small one.
        var maximumFlatnessRatio: Float = 0.35

        /// Hard ceiling on how far a single point may be moved. Anything
        /// further is refused rather than relocated.
        ///
        /// This is also the honest bound on what this filter can distort: a
        /// surface whose real curvature deviates from its local tangent
        /// plane by *less* than this cannot be told apart from noise around
        /// that plane, and will be smoothed. For a room that is the right
        /// trade — walls, floors and ceilings are flat and the noise is not
        /// — but it does mean a tightly curved object can lose up to this
        /// much of its curvature. Kept deliberately below the sensor's own
        /// noise-to-structure crossover for that reason.
        var maximumCorrectionMeters: Float = 0.02

        static let `default` = Options()
    }

    struct Result {
        var points: [PointCloudExportPoint]
        /// Points projected onto a fitted plane.
        var flattenedCount: Int
        /// Isolated points dropped for having no surface around them.
        var removedCount: Int
        /// Points left exactly as measured — not planar enough, or the
        /// correction would have been too large to be noise.
        var untouchedCount: Int
    }

    /// Returns the cloud with scatter thinned, plus a count of what it
    /// actually did — the caller shows those numbers rather than silently
    /// presenting processed points as raw measurements.
    ///
    /// O(points x neighbours), via a spatial hash sized to the search
    /// radius. Not for the autosave path: run it once where the cloud is
    /// consumed, off the main thread.
    static func denoise(_ points: [PointCloudExportPoint], options: Options = .default) -> Result {
        guard points.count > options.minimumNeighbors, options.neighborhoodRadiusMeters > 0 else {
            return Result(points: points, flattenedCount: 0, removedCount: 0, untouchedCount: points.count)
        }

        let cellSize = options.neighborhoodRadiusMeters
        var grid: [Int64: [Int32]] = [:]
        grid.reserveCapacity(points.count / 4)
        for (index, point) in points.enumerated() {
            guard point.position.x.isFinite, point.position.y.isFinite, point.position.z.isFinite else { continue }
            grid[ProScanConfig.voxelKey(for: point.position, cellSize: cellSize), default: []].append(Int32(index))
        }

        var output: [PointCloudExportPoint] = []
        output.reserveCapacity(points.count)
        var flattened = 0
        var removed = 0
        var untouched = 0

        let radiusSquared = options.neighborhoodRadiusMeters * options.neighborhoodRadiusMeters
        var neighborPositions: [SIMD3<Float>] = []
        neighborPositions.reserveCapacity(64)

        for point in points {
            let position = point.position
            guard position.x.isFinite, position.y.isFinite, position.z.isFinite else {
                // Not a measurement at all; drop rather than reason about it.
                removed += 1
                continue
            }

            neighborPositions.removeAll(keepingCapacity: true)
            // The search radius equals the cell size, so every point within
            // it lies in this cell or one of the 26 around it.
            for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 {
                        let offset = SIMD3<Float>(Float(dx), Float(dy), Float(dz)) * cellSize
                        let key = ProScanConfig.voxelKey(for: position + offset, cellSize: cellSize)
                        guard let bucket = grid[key] else { continue }
                        for index in bucket {
                            let candidate = points[Int(index)].position
                            if simd_distance_squared(candidate, position) <= radiusSquared {
                                neighborPositions.append(candidate)
                            }
                        }
                    }
                }
            }

            // `neighborPositions` includes the point itself.
            guard neighborPositions.count > options.minimumNeighbors else {
                removed += 1
                continue
            }

            guard let plane = fitPlane(to: neighborPositions),
                  plane.thicknessMeters <= options.maximumSurfaceThicknessMeters,
                  plane.flatnessRatio <= options.maximumFlatnessRatio else {
                output.append(point)
                untouched += 1
                continue
            }

            let signedDistance = simd_dot(position - plane.centroid, plane.normal)
            guard abs(signedDistance) <= options.maximumCorrectionMeters else {
                output.append(point)
                untouched += 1
                continue
            }

            var flattenedPoint = point
            flattenedPoint.position = position - plane.normal * signedDistance
            // The fitted plane's normal is a far better estimate of the
            // local surface direction than one point's own noisy normal;
            // keep it pointing the same way the measured one did rather than
            // flipping the surface inside out.
            flattenedPoint.normal = simd_dot(plane.normal, point.normal) < 0 ? -plane.normal : plane.normal
            output.append(flattenedPoint)
            flattened += 1
        }

        return Result(points: output, flattenedCount: flattened, removedCount: removed, untouchedCount: untouched)
    }

    // MARK: - Ajuste de plano

    struct Plane {
        var centroid: SIMD3<Float>
        /// Unit normal — the direction of least variance.
        var normal: SIMD3<Float>
        /// Standard deviation of the points' distance from the plane, in
        /// metres: how thick this "surface" actually is.
        var thicknessMeters: Float
        /// Variance along the normal over variance along the second-least
        /// spread axis. Near 0 for a clear surface, near 1 for a blob that
        /// happens to be small.
        var flatnessRatio: Float
    }

    /// Least-squares plane through a point set, via the eigenvector of its
    /// covariance matrix with the smallest eigenvalue (standard PCA plane
    /// fit). `nil` when the set is degenerate.
    static func fitPlane(to positions: [SIMD3<Float>]) -> Plane? {
        guard positions.count >= 3 else { return nil }

        var centroid = SIMD3<Float>.zero
        for position in positions { centroid += position }
        centroid /= Float(positions.count)

        var xx: Float = 0, xy: Float = 0, xz: Float = 0
        var yy: Float = 0, yz: Float = 0, zz: Float = 0
        for position in positions {
            let d = position - centroid
            xx += d.x * d.x; xy += d.x * d.y; xz += d.x * d.z
            yy += d.y * d.y; yz += d.y * d.z; zz += d.z * d.z
        }
        let count = Float(positions.count)
        let covariance = simd_float3x3(
            SIMD3<Float>(xx / count, xy / count, xz / count),
            SIMD3<Float>(xy / count, yy / count, yz / count),
            SIMD3<Float>(xz / count, yz / count, zz / count)
        )

        let (eigenvalues, eigenvectors) = symmetricEigenDecomposition(covariance)
        guard eigenvalues.x.isFinite, eigenvalues.y.isFinite, eigenvalues.z.isFinite else { return nil }

        // Sorted ascending: [0] is the least-spread axis (the normal), [1]
        // the next, which is what the flatness ratio is measured against.
        let order = [0, 1, 2].sorted { eigenvalues[$0] < eigenvalues[$1] }
        let smallest = max(eigenvalues[order[0]], 0)
        let middle = max(eigenvalues[order[1]], 0)
        guard middle > 0 else { return nil }

        let normal = eigenvectors[order[0]]
        let length = simd_length(normal)
        guard length > 0, length.isFinite else { return nil }

        return Plane(
            centroid: centroid,
            normal: normal / length,
            thicknessMeters: smallest.squareRoot(),
            flatnessRatio: smallest / middle
        )
    }

    /// Jacobi eigenvalue iteration for a symmetric 3x3 matrix.
    ///
    /// Written out rather than reached for in a library because simd offers
    /// no eigen decomposition, and the alternatives (inverse iteration, the
    /// closed-form cubic) are numerically fragile exactly where this is used
    /// most — a near-perfect plane, where two eigenvalues are nearly equal
    /// and the third is nearly zero. Jacobi is unconditionally stable for
    /// symmetric input and converges in a handful of sweeps at this size.
    ///
    /// Returns the eigenvalues and their matching (unit) eigenvectors.
    static func symmetricEigenDecomposition(_ matrix: simd_float3x3) -> (SIMD3<Float>, [SIMD3<Float>]) {
        var a = matrix
        var v = matrix_identity_float3x3

        for _ in 0..<24 {
            // Largest off-diagonal magnitude decides the rotation plane.
            var p = 0, q = 1
            var largest = abs(a[1][0])
            if abs(a[2][0]) > largest { largest = abs(a[2][0]); p = 0; q = 2 }
            if abs(a[2][1]) > largest { largest = abs(a[2][1]); p = 1; q = 2 }
            // Converged: the remaining off-diagonal mass is negligible.
            if largest < 1e-10 { break }

            let apq = a[q][p]
            let app = a[p][p]
            let aqq = a[q][q]
            let theta = (aqq - app) / (2 * apq)
            let t = (theta >= 0 ? 1 : -1) / (abs(theta) + (theta * theta + 1).squareRoot())
            let c = 1 / (t * t + 1).squareRoot()
            let s = t * c

            var rotation = matrix_identity_float3x3
            rotation[p][p] = c
            rotation[q][q] = c
            rotation[q][p] = s
            rotation[p][q] = -s

            a = rotation.transpose * a * rotation
            v = v * rotation
        }

        return (SIMD3<Float>(a[0][0], a[1][1], a[2][2]), [v.columns.0, v.columns.1, v.columns.2])
    }
}
