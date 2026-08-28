import simd

/// Fuses possibly-duplicate point observations landing in the same spatial
/// voxel into one representative point — replacing
/// `ARPointCloudSession`'s previous behavior of keeping every mesh
/// anchor's points as a separate, never-merged array: ARKit re-triangulates
/// a chunk's boundary as it refines the scan, so a vertex near two
/// neighboring anchors' shared edge would otherwise simply pile up as two
/// near-duplicate points instead of being fused into one (see the Pro Scan
/// audit's finding on this).
///
/// Confidence itself is a plain arithmetic mean across every observation
/// that landed in a voxel (matching `ConfidenceGrid`'s Fase 2 averaging);
/// position, color, and normal are averaged *weighted by* that per-sample
/// confidence, so a higher-confidence observation pulls the fused point
/// more strongly toward itself. `classification` isn't a continuous
/// quantity — averaging two raw enum values would be meaningless — so it's
/// resolved by majority vote instead (see `FaceClassificationVoting` below,
/// a related but distinct piece of math: that one propagates ARKit's
/// per-*face* classification to individual *vertices*, before any of this
/// voxel fusion happens).
///
/// Coordinate systems: positions/normals here are assumed to already be in
/// ARKit world space (right-handed, +Y up) — the same convention
/// `ProScanConfig` and `CameraUnprojection` document; this type performs no
/// coordinate conversion of its own.
///
/// Not an `actor`, for the same reason as `ConfidenceGrid`: every call site
/// in this phase is synchronous, single-threaded use (either entirely
/// within `ARPointCloudSession`'s serial `processingQueue`, or a one-shot
/// call at export time) — an actor would add `Task`/`await` boundaries
/// with no concurrency benefit here.
///
/// Pure Swift/simd, no ARKit dependency — like `ProScanConfig`,
/// `CameraUnprojection`, and `ConfidenceGrid` — so it compiles into the
/// host-less `StructuraTests` logic-test target.
final class VoxelAccumulator {
    /// A self-contained sample type (not `PointCloudExportPoint`)
    /// deliberately: keeping this file's only dependency on `ProScanConfig`
    /// avoids any question of whether `Export/PointCloud`'s CoreLocation
    /// import affects this host-less-testable module. `ARPointCloudSession`
    /// converts to/from `PointCloudExportPoint` at the one call site that
    /// needs to.
    struct Sample {
        var position: SIMD3<Float>
        var confidence: Float
        var color: SIMD3<Float>
        var normal: SIMD3<Float>
        /// Raw `PointCloudMeshClassification`/`ARMeshClassification` value
        /// (0...7) — kept as a plain byte here for the same reason as the
        /// rest of this type's ARKit/export-model independence.
        var classificationRawValue: UInt8
    }

    private struct Cell {
        var weightedPositionSum: SIMD3<Float> = .zero
        var weightedColorSum: SIMD3<Float> = .zero
        var weightedNormalSum: SIMD3<Float> = .zero
        var confidenceSum: Float = 0
        var weightSum: Float = 0
        var observationCount: Int = 0
        var classificationVotes: [UInt8: Int] = [:]
    }

    private var cells: [Int64: Cell] = [:]

    func reset() {
        cells.removeAll(keepingCapacity: false)
    }

    /// Number of distinct voxels observed so far — after fusion, this is
    /// exactly the count `fusedSamples()` will return.
    var observedVoxelCount: Int { cells.count }

    /// Folds one observed sample into its voxel's running weighted average.
    /// Confidence is clamped to a small positive floor for weighting
    /// purposes only (so a same-position duplicate can never be given zero
    /// influence over the fused position/color/normal); the *reported*
    /// fused confidence still uses the sample's real, unclamped value.
    func record(_ sample: Sample) {
        let key = Self.voxelKey(for: sample.position)
        var cell = cells[key] ?? Cell()
        let weight = max(sample.confidence, 0.0001)
        cell.weightedPositionSum += sample.position * weight
        cell.weightedColorSum += sample.color * weight
        cell.weightedNormalSum += sample.normal * weight
        cell.confidenceSum += sample.confidence
        cell.weightSum += weight
        cell.observationCount += 1
        cell.classificationVotes[sample.classificationRawValue, default: 0] += 1
        cells[key] = cell
    }

    /// One fused representative sample per observed voxel.
    func fusedSamples() -> [Sample] {
        cells.values.map { cell in
            let position = cell.weightedPositionSum / cell.weightSum
            let color = cell.weightedColorSum / cell.weightSum
            let normalLength = simd_length(cell.weightedNormalSum)
            let normal = normalLength > 0 ? cell.weightedNormalSum / normalLength : SIMD3<Float>(0, 1, 0)
            let confidence = cell.confidenceSum / Float(cell.observationCount)
            let classification = Self.majorityClassification(from: cell.classificationVotes)
            return Sample(position: position, confidence: confidence, color: color, normal: normal, classificationRawValue: classification)
        }
    }

    /// Highest-vote-count classification; ties broken by lowest raw value,
    /// for a fully deterministic result. `.none` (0) if there were no votes
    /// at all (a voxel fed only by the raw depth pipeline, never by any
    /// mesh vertex — not expected in practice, but handled rather than
    /// crashing on an empty tally).
    private static func majorityClassification(from votes: [UInt8: Int]) -> UInt8 {
        var bestValue: UInt8 = 0
        var bestCount = -1
        for rawValue in votes.keys.sorted() {
            let count = votes[rawValue]!
            if count > bestCount {
                bestCount = count
                bestValue = rawValue
            }
        }
        return bestValue
    }

    /// Packs a world-space position into a voxel-grid cell key, at
    /// `ProScanConfig.voxelSizeMeters` resolution. Matches the packing
    /// scheme already shipping in `PointCloudStore.voxelKey(for:)` and
    /// `ConfidenceGrid.voxelKey(for:)`: three 20-bit signed cell
    /// coordinates packed into one `Int64`.
    static func voxelKey(for position: SIMD3<Float>) -> Int64 {
        let x = Int64((position.x / ProScanConfig.voxelSizeMeters).rounded()) & 0x1FFFFF
        let y = Int64((position.y / ProScanConfig.voxelSizeMeters).rounded()) & 0x1FFFFF
        let z = Int64((position.z / ProScanConfig.voxelSizeMeters).rounded()) & 0x1FFFFF
        return (x << 42) | (y << 21) | z
    }
}

/// Propagates ARKit's per-*face* mesh classification (`ARMeshGeometry
/// .classification`, one raw byte per triangle) to individual *vertices* —
/// a distinct piece of math from `VoxelAccumulator` above, bundled in the
/// same file because both are mesh-point-enrichment utilities introduced
/// together in this phase, and both are small enough not to warrant
/// separate files of their own.
///
/// Pure Swift, no ARKit dependency: operates on plain index/byte arrays so
/// it's directly testable with synthetic data instead of a real
/// `ARMeshAnchor` (which has no public initializer usable in a unit test).
enum FaceClassificationVoting {
    /// For each vertex index in `sampledVertexIndices`, tallies a vote from
    /// every face that references it, and resolves the majority classification
    /// (ties broken by lowest raw value). A sampled vertex referenced by zero
    /// faces isn't included in the result at all — callers should treat a
    /// missing entry the same as `.none`.
    static func majorityClassifications(
        faceVertexIndices: [(Int, Int, Int)],
        faceClassificationRawValues: [UInt8],
        sampledVertexIndices: Set<Int>
    ) -> [Int: UInt8] {
        precondition(
            faceVertexIndices.count == faceClassificationRawValues.count,
            "One classification byte is expected per face."
        )

        var votes: [Int: [UInt8: Int]] = [:]
        for faceIndex in faceVertexIndices.indices {
            let (v0, v1, v2) = faceVertexIndices[faceIndex]
            let rawValue = faceClassificationRawValues[faceIndex]
            for vertexIndex in [v0, v1, v2] where sampledVertexIndices.contains(vertexIndex) {
                votes[vertexIndex, default: [:]][rawValue, default: 0] += 1
            }
        }

        return votes.mapValues { tally in
            var bestValue: UInt8 = 0
            var bestCount = -1
            for rawValue in tally.keys.sorted() {
                let count = tally[rawValue]!
                if count > bestCount {
                    bestCount = count
                    bestValue = rawValue
                }
            }
            return bestValue
        }
    }
}
