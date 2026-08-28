import simd

/// A coarse post-capture coverage/"holes" signal for the QA panel: what
/// fraction of the scan's own bounding box actually has data in it, at a
/// deliberately coarse voxel resolution (see
/// `ProScanConfig.coverageVoxelSizeMeters`).
///
/// This is explicitly *not* real topological hole detection (finding the
/// boundary of an actual gap in a surface) — that needs real mesh
/// topology, which the exported point cloud doesn't retain (see the Pro
/// Scan plan's Fase 3 notes). A low coverage ratio here means "there's
/// real empty space within the scan's own extent", which is a legitimate,
/// honest signal even though it can't point at the gap's exact shape.
enum ScanCoverageEstimator {
    struct Report {
        var occupiedVoxelCount: Int
        var boundingBoxVoxelCount: Int
        /// `occupiedVoxelCount / boundingBoxVoxelCount` — 1.0 means every
        /// cell within the bounding box holds at least one point.
        var coverageRatio: Float
    }

    static func estimateCoverage(of points: [PointCloudExportPoint], voxelSize: Float) -> Report? {
        guard !points.isEmpty, voxelSize > 0, voxelSize.isFinite else { return nil }

        var minPosition: SIMD3<Float>?
        var maxPosition: SIMD3<Float>?
        var occupied: Set<Int64> = []
        occupied.reserveCapacity(points.count)

        for point in points {
            let position = point.position
            guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { continue }
            minPosition = minPosition.map { simd_min($0, position) } ?? position
            maxPosition = maxPosition.map { simd_max($0, position) } ?? position
            occupied.insert(voxelKey(for: position, voxelSize: voxelSize))
        }

        guard let minPosition, let maxPosition else { return nil }

        // `voxelKey` assigns a cell index via `round(position / voxelSize)`
        // (nearest, not floor) — so the number of *distinct* indices a span
        // of `extent` can touch is `round(extent / voxelSize) + 1` (a
        // fencepost: e.g. positions 0.0 and 0.4 at a 0.1 voxel size are 4
        // voxel-widths apart but land in 5 distinct cells: 0,1,2,3,4).
        // Using `ceil(extent/voxelSize)` without the `+1` undercounts by
        // exactly one cell per axis, which can push `coverageRatio` above
        // 1.0 for a fully-occupied bounding box — caught by
        // `testFullyDensePointsReportFullCoverage`.
        let extent = maxPosition - minPosition
        let cellsX = max(1, Int((extent.x / voxelSize).rounded()) + 1)
        let cellsY = max(1, Int((extent.y / voxelSize).rounded()) + 1)
        let cellsZ = max(1, Int((extent.z / voxelSize).rounded()) + 1)
        let totalCells = cellsX * cellsY * cellsZ
        guard totalCells > 0 else { return nil }

        return Report(
            occupiedVoxelCount: occupied.count,
            boundingBoxVoxelCount: totalCells,
            coverageRatio: Float(occupied.count) / Float(totalCells)
        )
    }

    private static func voxelKey(for position: SIMD3<Float>, voxelSize: Float) -> Int64 {
        let x = Int64((position.x / voxelSize).rounded()) & 0x1FFFFF
        let y = Int64((position.y / voxelSize).rounded()) & 0x1FFFFF
        let z = Int64((position.z / voxelSize).rounded()) & 0x1FFFFF
        return (x << 42) | (y << 21) | z
    }
}
