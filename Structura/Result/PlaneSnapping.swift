import simd

/// "Snap to plane": given a tapped point, fits a local plane from the
/// *real, already-computed* per-point normals in its neighborhood
/// (`VoxelAccumulator`'s confidence-weighted normal fusion, not a
/// re-derived PCA estimate — the data already exists) and projects the tap
/// onto it, trading the raw sample's noise for the averaged neighborhood's
/// stability.
///
/// Deliberately does **not** attempt automatic edge/corner detection: a
/// classifier that splits a neighborhood into multiple planes needs
/// thresholds tuned against real, noisy device scans to be trustworthy,
/// and shipping one unvalidated would assert a robustness this code can't
/// actually back up. When a neighborhood isn't flat enough to trust a
/// single plane (`maxAngularSpread` too high, or too few neighbors), the
/// caller should fall back to the raw tapped point — never fabricate a fit.
enum PlaneSnapping {
    struct Plane {
        /// A point on the plane (the neighborhood's centroid).
        var point: SIMD3<Float>
        /// Unit normal.
        var normal: SIMD3<Float>
    }

    /// The largest angle (radians) between any single neighbor's normal
    /// and the neighborhood's own mean normal — an O(n) proxy for "how flat
    /// is this neighborhood", cheaper than the O(n²) largest-pairwise-angle
    /// it approximates. Returns `nil` for an empty or all-zero-normal input.
    static func maxAngularSpread(of normals: [SIMD3<Float>]) -> Float? {
        guard !normals.isEmpty else { return nil }
        let sum = normals.reduce(SIMD3<Float>.zero, +)
        let sumLength = simd_length(sum)
        guard sumLength > 0 else { return nil }
        let mean = sum / sumLength

        var maxAngle: Float = 0
        for normal in normals {
            let normalLength = simd_length(normal)
            guard normalLength > 0 else { continue }
            let cosAngle = simd_dot(normal / normalLength, mean)
            let angle = acos(min(1, max(-1, cosAngle)))
            maxAngle = max(maxAngle, angle)
        }
        return maxAngle
    }

    /// Fits a plane to every point within `radius` of `center` — the
    /// centroid of their positions, and their confidence-weighted-fused
    /// normals re-averaged and renormalized. Returns `nil` if fewer than
    /// `minimumNeighbors` points qualify, or the neighborhood isn't flat
    /// enough (see `maxAngularSpread` vs `maxAngularSpreadRadians`) — both
    /// cases mean "don't trust a plane here", not "here's a rough one".
    static func fitPlane(
        around center: SIMD3<Float>,
        in points: [PointCloudExportPoint],
        radius: Float,
        minimumNeighbors: Int,
        maxAngularSpreadRadians: Float
    ) -> Plane? {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        for point in points where simd_distance(point.position, center) <= radius {
            positions.append(point.position)
            normals.append(point.normal)
        }
        guard positions.count >= minimumNeighbors else { return nil }

        guard let spread = maxAngularSpread(of: normals), spread <= maxAngularSpreadRadians else { return nil }

        let centroid = positions.reduce(SIMD3<Float>.zero, +) / Float(positions.count)
        let normalSum = normals.reduce(SIMD3<Float>.zero, +)
        let normalSumLength = simd_length(normalSum)
        guard normalSumLength > 0 else { return nil }

        return Plane(point: centroid, normal: normalSum / normalSumLength)
    }

    /// The closest point on `plane` to `position` — the actual "snap".
    static func project(_ position: SIMD3<Float>, onto plane: Plane) -> SIMD3<Float> {
        let signedDistance = simd_dot(position - plane.point, plane.normal)
        return position - signedDistance * plane.normal
    }
}
