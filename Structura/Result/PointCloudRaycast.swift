import simd

/// Finds the point-cloud sample nearest a 3D ray — the "raycast" a tap
/// gesture in `PointCloudSceneView` needs, since the scene has no triangle
/// mesh to hit-test against (Pro Scan's export is a fused point cloud with
/// per-point normals, not mesh topology — see the Pro Scan plan's Fase 3
/// notes on why `VoxelAccumulator` doesn't retain face connectivity).
///
/// A linear scan is used deliberately: this runs once per user tap, not
/// once per frame, so its O(N) cost is negligible next to interaction
/// latency, and it avoids the complexity of a spatial index for a query
/// pattern that doesn't need one at this frequency.
enum PointCloudRaycast {
    struct Hit {
        var pointIndex: Int
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
    }

    /// `rayDirection` need not be normalized. Returns the point whose
    /// perpendicular distance to the ray is smallest, among points both
    /// *ahead* of `rayOrigin` (not behind the camera) and within
    /// `maxPerpendicularDistance` of the ray line.
    static func nearestPoint(
        in points: [PointCloudExportPoint],
        rayOrigin: SIMD3<Float>,
        rayDirection: SIMD3<Float>,
        maxPerpendicularDistance: Float
    ) -> Hit? {
        let directionLength = simd_length(rayDirection)
        guard directionLength > 0 else { return nil }
        let direction = rayDirection / directionLength

        var bestIndex: Int?
        var bestPerpendicularDistance = Float.greatestFiniteMagnitude

        for (index, point) in points.enumerated() {
            let toPoint = point.position - rayOrigin
            let alongRay = simd_dot(toPoint, direction)
            guard alongRay > 0 else { continue }
            let closestPointOnRay = rayOrigin + direction * alongRay
            let perpendicularDistance = simd_distance(point.position, closestPointOnRay)
            guard perpendicularDistance <= maxPerpendicularDistance else { continue }
            if perpendicularDistance < bestPerpendicularDistance {
                bestPerpendicularDistance = perpendicularDistance
                bestIndex = index
            }
        }

        guard let bestIndex else { return nil }
        let point = points[bestIndex]
        return Hit(pointIndex: bestIndex, position: point.position, normal: point.normal)
    }
}
