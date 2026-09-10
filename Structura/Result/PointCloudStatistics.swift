import simd

/// The scan's own measurable facts — extent, density, confidence — for the
/// 3D inspector's statistics panel and for the engineering bounding box the
/// viewer draws around the cloud.
///
/// Separate from `ScanCoverageEstimator` (which answers "how much of the
/// scan's extent has *any* data in it") and from `ScanMetadataReport` (which
/// is the exported sidecar): this is what the on-screen inspector needs, and
/// it deliberately reports density two different ways because a single
/// "points per m³" number is misleading for a room scan.
enum PointCloudStatistics {

    /// Axis-aligned bounds in ARKit's own frame (+Y up, metres) — the same
    /// frame the SceneKit viewer draws in, so the box the user sees is the
    /// box these numbers describe. The +Z-up conversion belongs to export
    /// (`TopographicAxisConvention`), not here.
    struct BoundingBox: Equatable {
        var minimum: SIMD3<Float>
        var maximum: SIMD3<Float>

        /// Width (X), height (Y) and depth (Z) in metres.
        var extent: SIMD3<Float> { maximum - minimum }
        var center: SIMD3<Float> { (minimum + maximum) / 2 }
        var diagonalMeters: Float { simd_length(extent) }

        /// Volume of the box itself. For a room-shaped scan this is mostly
        /// empty air — see `Report.densityPerCubicMeter`'s doc comment.
        var volumeCubicMeters: Float {
            let extent = self.extent
            return extent.x * extent.y * extent.z
        }
    }

    struct Report: Equatable {
        var pointCount: Int
        var boundingBox: BoundingBox

        /// Points per cubic metre of the **bounding box**.
        ///
        /// Honest but rarely the number a user wants: a LiDAR scan captures
        /// *surfaces*, so the box enclosing a room is almost entirely empty
        /// space, and this figure drops as the scan covers more ground —
        /// which reads backwards. Reported anyway because it is the
        /// conventional reading of "density per m³", and hiding it would
        /// just invite someone to recompute it wrong.
        var densityPerCubicMeter: Float

        /// Points per cubic metre of the volume actually **occupied** by the
        /// scan — the strict figure.
        ///
        /// Occupancy is measured on the same coarse voxel grid
        /// `ScanCoverageEstimator` uses, and the volume is that cell count
        /// times the cell volume. Because it divides by the space the scan
        /// really fills rather than by the box around it, this stays
        /// comparable between a small dense capture and a large one, and is
        /// what the inspector shows as the headline density.
        var strictDensityPerCubicMeter: Float

        /// Occupied volume behind `strictDensityPerCubicMeter`, in m³.
        var occupiedVolumeCubicMeters: Float

        /// Mean confidence over points whose confidence was really observed
        /// by the depth pipeline. Points carrying only the fallback value
        /// are excluded rather than averaged in as if they were readings —
        /// same rule `ScanMetadataReport` follows (audit finding E2).
        var meanObservedConfidence: Float

        /// Fraction of points that carry a real confidence observation.
        /// `meanObservedConfidence` describes only this share of the cloud,
        /// so the two belong together.
        var observedConfidenceFraction: Float
    }

    /// `nil` for an empty cloud, or one whose every point is non-finite —
    /// there is no extent to report, which is different from reporting a
    /// zero-sized box at the origin.
    ///
    /// One pass here for bounds and confidence; occupancy is delegated to
    /// `ScanCoverageEstimator` rather than recomputed, so the voxel-key
    /// hashing lives in one place (the architecture audit's finding E3 was
    /// precisely that this key had been copied across files) and "occupied"
    /// means the same thing in the inspector as it does in the QA panel.
    ///
    /// Call it off the main thread, like every other whole-cloud pass here.
    static func make(
        of points: [PointCloudExportPoint],
        occupancyVoxelSize: Float = ProScanConfig.coverageVoxelSizeMeters
    ) -> Report? {
        guard !points.isEmpty, occupancyVoxelSize > 0, occupancyVoxelSize.isFinite else { return nil }

        var minimum: SIMD3<Float>?
        var maximum: SIMD3<Float>?
        var confidenceSum: Float = 0
        var observedCount = 0
        var finiteCount = 0

        for point in points {
            let position = point.position
            guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { continue }
            finiteCount += 1
            minimum = minimum.map { simd_min($0, position) } ?? position
            maximum = maximum.map { simd_max($0, position) } ?? position
            if point.isConfidenceObserved {
                confidenceSum += point.confidence
                observedCount += 1
            }
        }

        guard let minimum, let maximum, finiteCount > 0 else { return nil }

        let boundingBox = BoundingBox(minimum: minimum, maximum: maximum)
        let coverage = ScanCoverageEstimator.estimateCoverage(of: points, voxelSize: occupancyVoxelSize)
        let occupiedVolume = Float(coverage?.occupiedVoxelCount ?? 0) * pow(occupancyVoxelSize, 3)

        return Report(
            pointCount: finiteCount,
            boundingBox: boundingBox,
            // A flat or single-point cloud has zero box volume; report zero
            // rather than an infinity that would render as "inf pts/m³".
            densityPerCubicMeter: boundingBox.volumeCubicMeters > 0
                ? Float(finiteCount) / boundingBox.volumeCubicMeters
                : 0,
            strictDensityPerCubicMeter: occupiedVolume > 0
                ? Float(finiteCount) / occupiedVolume
                : 0,
            occupiedVolumeCubicMeters: occupiedVolume,
            meanObservedConfidence: observedCount > 0 ? confidenceSum / Float(observedCount) : 0,
            observedConfidenceFraction: Float(observedCount) / Float(finiteCount)
        )
    }
}
