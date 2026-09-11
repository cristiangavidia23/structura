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
/// # Incremental use (Fase 1 of the architecture audit)
///
/// Every quantity a `Cell` holds is a running *sum*, so an observation can
/// be withdrawn as exactly as it was added — that is what `remove(_:)`
/// does. This is what lets `ARPointCloudSession` keep **one long-lived
/// accumulator** across a whole capture instead of rebuilding a fresh one
/// from every stored sample on each call: when ARKit re-triangulates a
/// chunk, the session withdraws that anchor's previous samples and records
/// its new ones, an O(vertices-in-that-chunk) operation, rather than an
/// O(points-in-the-entire-scan) rebuild on the main thread (audit finding
/// C1). A cell whose last observation is withdrawn is dropped outright, so
/// an emptied region resets exactly rather than lingering as accumulated
/// floating-point residue.
///
/// Repeated record/remove cycles do accrue floating-point drift in the
/// running sums, bounded by the magnitudes involved (positions in meters,
/// weights in 0…1) and by cells being dropped at zero. Where an
/// authoritative result matters more than the cost — the final export, not
/// a 10-second autosave — `rebuilt(from:)` produces a fresh accumulator
/// with no accumulated residue at all.
///
/// Coordinate systems: positions/normals here are assumed to already be in
/// ARKit world space (right-handed, +Y up) — the same convention
/// `ProScanConfig` and `CameraUnprojection` document; this type performs no
/// coordinate conversion of its own.
///
/// Not an `actor`: call sites are synchronous, single-threaded use (either
/// entirely within `ARPointCloudSession`'s mesh-processing queue, or a
/// one-shot call at export time) — an actor would add `Task`/`await`
/// boundaries with no concurrency benefit here. The session guards it with
/// the same lock that guards its per-anchor sample storage, since the two
/// must be mutated together to stay consistent.
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
        /// `false` when `confidence` above is a fallback value — no real
        /// `ConfidenceGrid` observation existed for this vertex — rather
        /// than a genuine depth-pipeline reading. Fase 2 of the
        /// architecture audit, finding E2: the fallback confidence number
        /// itself is unchanged (still needed so PLY/rendering have *some*
        /// float to work with), but callers that must not present a
        /// fabricated value as real data (`LASExporter`'s Intensity field)
        /// need this flag to tell the two cases apart. Defaults to `true`
        /// so existing construction sites/tests that never set it keep
        /// compiling unchanged.
        var isConfidenceObserved: Bool = true
    }

    /// `PointCloudMeshClassification` has exactly eight cases (`none`
    /// through `door`), mirroring ARKit's `ARMeshClassification`. Fixing the
    /// tally at eight lanes is what keeps `Cell` a flat value type.
    static let classificationCount = 8

    /// Every field is a running sum, which is what makes `remove(_:)`
    /// exact rather than approximate.
    ///
    /// `classificationVotes` is a fixed `SIMD8<Int32>`, not a
    /// `[UInt8: Int]`. The dictionary version cost one heap allocation per
    /// occupied voxel — hundreds of thousands of tiny dictionaries on a
    /// real scan, rebuilt in full on every export/autosave call (audit
    /// finding C2). Eight lanes cover every classification ARKit emits, so
    /// the tally now lives inline in the cell with no allocation at all.
    private struct Cell {
        var weightedPositionSum: SIMD3<Float> = .zero
        var weightedColorSum: SIMD3<Float> = .zero
        var weightedNormalSum: SIMD3<Float> = .zero
        var confidenceSum: Float = 0
        var weightSum: Float = 0
        var observationCount: Int32 = 0
        var classificationVotes: SIMD8<Int32> = .zero
        /// How many of this cell's contributing samples carried a real
        /// `ConfidenceGrid` observation (`Sample.isConfidenceObserved ==
        /// true`), not a fallback value — Fase 2, finding E2. The fused
        /// sample reports `isConfidenceObserved` as this count being > 0:
        /// "at least one real observation contributed here," the honest
        /// threshold for "this point's confidence isn't entirely made up,"
        /// as opposed to requiring *every* contributing sample to be real
        /// (which would make one lone real observation among many
        /// fallbacks count as unobserved, discarding the one genuine
        /// signal this cell actually has).
        var observedConfidenceCount: Int32 = 0
    }

    private var cells: [Int64: Cell] = [:]

    func reset() {
        cells.removeAll(keepingCapacity: false)
    }

    /// Number of distinct voxels observed so far — after fusion, this is
    /// exactly the count `fusedSamples()` will return.
    var observedVoxelCount: Int { cells.count }

    /// Weight used for position/color/normal averaging. Clamped to a small
    /// positive floor so a zero-confidence duplicate can never be given
    /// zero influence over the fused values; the *reported* fused
    /// confidence still uses the sample's real, unclamped value.
    ///
    /// `record` and `remove` must derive the weight identically, or a
    /// withdrawal would not cancel its own contribution — hence the single
    /// shared definition here rather than the expression inlined twice.
    private static func weight(for sample: Sample) -> Float {
        max(sample.confidence, 0.0001)
    }

    /// Folds one observed sample into its voxel's running weighted average.
    func record(_ sample: Sample) {
        let key = Self.voxelKey(for: sample.position)
        let weight = Self.weight(for: sample)
        var cell = cells[key] ?? Cell()
        cell.weightedPositionSum += sample.position * weight
        cell.weightedColorSum += sample.color * weight
        cell.weightedNormalSum += sample.normal * weight
        cell.confidenceSum += sample.confidence
        cell.weightSum += weight
        cell.observationCount += 1
        if sample.isConfidenceObserved {
            cell.observedConfidenceCount += 1
        }
        if let lane = Self.voteLane(for: sample.classificationRawValue) {
            cell.classificationVotes[lane] += 1
        }
        cells[key] = cell
    }

    /// Withdraws a previously recorded sample, exactly cancelling the
    /// contribution `record(_:)` made for it. Passing a sample that was
    /// never recorded (or recording it twice and removing it once too
    /// often) is a caller bug: the cell's observation count would go
    /// negative, so it is dropped instead, which is the conservative
    /// outcome — a lost voxel rather than a corrupt one.
    ///
    /// This is what makes an anchor's re-triangulation cheap: withdraw the
    /// chunk's previous vertices, record its new ones, and the fused set
    /// stays correct without touching any other anchor's points.
    func remove(_ sample: Sample) {
        let key = Self.voxelKey(for: sample.position)
        guard var cell = cells[key] else { return }

        let weight = Self.weight(for: sample)
        cell.weightedPositionSum -= sample.position * weight
        cell.weightedColorSum -= sample.color * weight
        cell.weightedNormalSum -= sample.normal * weight
        cell.confidenceSum -= sample.confidence
        cell.weightSum -= weight
        cell.observationCount -= 1
        if sample.isConfidenceObserved {
            cell.observedConfidenceCount = max(cell.observedConfidenceCount - 1, 0)
        }
        if let lane = Self.voteLane(for: sample.classificationRawValue) {
            cell.classificationVotes[lane] = max(cell.classificationVotes[lane] - 1, 0)
        }

        // Dropping the cell at zero keeps an emptied region exactly empty,
        // rather than leaving a residue of near-cancelled sums behind that
        // a later observation would then be averaged against.
        if cell.observationCount <= 0 || cell.weightSum <= 0 {
            cells.removeValue(forKey: key)
        } else {
            cells[key] = cell
        }
    }

    /// Records every sample in a sequence. Convenience for the session's
    /// per-anchor ingestion, which always deals in whole chunks.
    func record<S: Sequence>(contentsOf samples: S) where S.Element == Sample {
        for sample in samples { record(sample) }
    }

    /// Withdraws every sample in a sequence — the counterpart used when an
    /// anchor is re-triangulated or removed.
    func remove<S: Sequence>(contentsOf samples: S) where S.Element == Sample {
        for sample in samples { remove(sample) }
    }

    /// One fused representative sample per observed voxel.
    ///
    /// Sorted by voxel key so the exported point order is deterministic
    /// across runs — `Dictionary` iteration order is not stable, and an
    /// export whose point order changes between two identical scans is
    /// needlessly hard to diff or regression-test.
    /// `sorted` buys a deterministic point order, at the cost of sorting
    /// every occupied voxel key — tens of milliseconds once the depth path
    /// pushes this into the hundreds of thousands, while the caller holds
    /// the lock the capture pipeline needs.
    ///
    /// Worth paying at the final export, where a stable order is what makes
    /// two runs of the same scan diffable. Not worth paying on the autosave
    /// timer, which overwrites the same crash-recovery file every few
    /// seconds and whose point order nothing reads.
    func fusedSamples(sorted: Bool = true) -> [Sample] {
        let keys = sorted ? cells.keys.sorted() : Array(cells.keys)
        return keys.map { key in
            let cell = cells[key]!
            let position = cell.weightedPositionSum / cell.weightSum
            let color = cell.weightedColorSum / cell.weightSum
            let normalLength = simd_length(cell.weightedNormalSum)
            let normal = normalLength > 0 ? cell.weightedNormalSum / normalLength : SIMD3<Float>(0, 1, 0)
            let confidence = cell.confidenceSum / Float(cell.observationCount)
            let classification = Self.majorityClassification(from: cell.classificationVotes)
            return Sample(
                position: position, confidence: confidence, color: color, normal: normal,
                classificationRawValue: classification,
                isConfidenceObserved: cell.observedConfidenceCount > 0
            )
        }
    }

    /// A fresh accumulator built from scratch out of `samples`, carrying no
    /// floating-point residue from any record/remove history. Use at the
    /// final export, where paying O(N) once buys an authoritative result;
    /// not on the autosave path, which is exactly the O(N)-on-the-main-
    /// thread cost Fase 1 removes.
    static func rebuilt<S: Sequence>(from samples: S) -> VoxelAccumulator where S.Element == Sample {
        let accumulator = VoxelAccumulator()
        accumulator.record(contentsOf: samples)
        return accumulator
    }

    /// Classification raw value meaning **"this sample has no opinion"**, as
    /// distinct from `.none`, which means "observed, and unclassified".
    ///
    /// The distinction became load-bearing when the LiDAR depth path started
    /// feeding the cloud: ARKit classifies scene-*mesh* faces, not depth
    /// pixels, so a depth sample simply has no label to report. Letting it
    /// carry `.none` would have made it a *vote* for "unclassified" — and
    /// since the depth path is one to two orders of magnitude denser than
    /// the mesh path, those non-votes would have outvoted and erased every
    /// real wall/floor/ceiling/door label ARKit did produce, across the
    /// whole export.
    ///
    /// Deliberately outside the range `voteLane(for:)` accepts, so a sample
    /// carrying it is excluded from the tally by the mechanism already there
    /// for unrecognized values, rather than by a second special case. It
    /// never reaches an export: `majorityClassification(from:)` only ever
    /// returns a real lane, falling back to `.none` for a voxel where
    /// nobody had an opinion — which is the honest answer for a point only
    /// the depth path ever saw.
    static let unclassifiedRawValue: UInt8 = .max

    /// Maps a raw classification byte to its tally lane, or `nil` for a
    /// value outside the eight ARKit defines — an unknown byte is not
    /// counted rather than silently folded into `.none`, so a future ARKit
    /// case showing up here is invisible in the vote instead of being
    /// miscounted as "no classification".
    private static func voteLane(for rawValue: UInt8) -> Int? {
        let lane = Int(rawValue)
        return lane < classificationCount ? lane : nil
    }

    /// Highest-vote-count classification; ties broken by lowest raw value,
    /// for a fully deterministic result (the ascending scan keeps the first
    /// lane that reached the current maximum). `.none` (0) if there were no
    /// votes at all — a voxel fed only by the raw depth pipeline, never by
    /// any mesh vertex.
    private static func majorityClassification(from votes: SIMD8<Int32>) -> UInt8 {
        var bestValue = 0
        var bestCount: Int32 = -1
        for lane in 0..<classificationCount where votes[lane] > bestCount {
            bestCount = votes[lane]
            bestValue = lane
        }
        return UInt8(bestValue)
    }

    /// Forwards to `ProScanConfig.voxelKey(for:)` — the single source of
    /// truth for this packing scheme since Fase 2 of the architecture audit
    /// (finding E3: the same math used to be hand-copied here,
    /// `ConfidenceGrid`, and `PointCloudStore`). Kept as a same-named static
    /// method on this type, rather than switching every call site to
    /// `ProScanConfig.voxelKey(for:)` directly, so existing callers/tests
    /// (`VoxelAccumulatorTests`) don't need to change.
    static func voxelKey(for position: SIMD3<Float>) -> Int64 {
        ProScanConfig.voxelKey(for: position)
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
