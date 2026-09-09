import simd
import XCTest

/// Numeric acceptance tests for `VoxelAccumulator`, per the Fase 3
/// verification plan: two observations of the same point with confidences
/// 0.3 and 0.9 must land in one voxel with the correct weighted average,
/// and the point count after fusion must measurably drop versus the
/// previous plain-concatenation behavior on an overlapping scan.
final class VoxelAccumulatorTests: XCTestCase {

    private func sample(
        _ position: SIMD3<Float>,
        confidence: Float,
        color: SIMD3<Float> = SIMD3(0.5, 0.5, 0.5),
        normal: SIMD3<Float> = SIMD3(0, 1, 0),
        classification: UInt8 = 0
    ) -> VoxelAccumulator.Sample {
        VoxelAccumulator.Sample(position: position, confidence: confidence, color: color, normal: normal, classificationRawValue: classification)
    }

    // MARK: - Weighted averaging (the plan's literal verification criterion)

    func testTwoObservationsOfTheSamePointFuseWithCorrectWeightedConfidence() throws {
        let accumulator = VoxelAccumulator()
        let position = SIMD3<Float>(1, 2, 3)
        accumulator.record(sample(position, confidence: 0.3))
        accumulator.record(sample(position, confidence: 0.9))

        let fused = accumulator.fusedSamples()
        XCTAssertEqual(fused.count, 1, "Both observations land in the same voxel and must fuse into one point.")
        let point = try XCTUnwrap(fused.first)
        XCTAssertEqual(point.confidence, 0.6, accuracy: 0.0001, "Confidence is a plain mean across every observation of a voxel.")
    }

    func testPositionIsPulledTowardTheHigherConfidenceObservation() throws {
        // Two distinct points close enough to land in the same voxel
        // (`ProScanConfig.voxelSizeMeters` is 0.02 m, so both round to the
        // same cell — 0.005 m is well inside half a voxel).
        let lowConfidencePosition = SIMD3<Float>(0, 0, 0)
        let highConfidencePosition = SIMD3<Float>(0.005, 0, 0)

        let accumulator = VoxelAccumulator()
        accumulator.record(sample(lowConfidencePosition, confidence: 0.1))
        accumulator.record(sample(highConfidencePosition, confidence: 0.9))

        let fused = try XCTUnwrap(accumulator.fusedSamples().first)
        // Weighted mean: (0*0.1 + 0.005*0.9) / (0.1+0.9) = 0.0045
        XCTAssertEqual(fused.position.x, 0.0045, accuracy: 0.0001)
        XCTAssertGreaterThan(fused.position.x, 0.0025, "The fused position must sit closer to the higher-confidence sample, not the midpoint.")
    }

    func testColorAndNormalAreAlsoConfidenceWeighted() throws {
        let position = SIMD3<Float>(5, 5, 5)
        let accumulator = VoxelAccumulator()
        accumulator.record(sample(position, confidence: 0.1, color: SIMD3(0, 0, 0), normal: SIMD3(1, 0, 0)))
        accumulator.record(sample(position, confidence: 0.9, color: SIMD3(1, 1, 1), normal: SIMD3(0, 1, 0)))

        let fused = try XCTUnwrap(accumulator.fusedSamples().first)
        // Weighted mean: (0*0.1 + 1*0.9) / 1.0 = 0.9 per channel.
        XCTAssertEqual(fused.color.x, 0.9, accuracy: 0.0001)
        XCTAssertEqual(fused.color.y, 0.9, accuracy: 0.0001)
        // Normal is re-normalized after weighted summation — length 1.
        XCTAssertEqual(simd_length(fused.normal), 1.0, accuracy: 0.0001)
        XCTAssertGreaterThan(fused.normal.y, fused.normal.x, "The normal must lean toward the higher-confidence observation's direction.")
    }

    // MARK: - Classification majority vote

    func testClassificationResolvesByMajorityVote() throws {
        let position = SIMD3<Float>(2, 2, 2)
        let accumulator = VoxelAccumulator()
        accumulator.record(sample(position, confidence: 0.5, classification: 1)) // wall
        accumulator.record(sample(position, confidence: 0.5, classification: 1)) // wall
        accumulator.record(sample(position, confidence: 0.9, classification: 2)) // floor — higher confidence, but fewer votes

        let fused = try XCTUnwrap(accumulator.fusedSamples().first)
        XCTAssertEqual(fused.classificationRawValue, 1, "Majority vote (2 wall vs. 1 floor) must win regardless of individual confidence.")
    }

    func testClassificationTieBreaksByLowestRawValue() throws {
        let position = SIMD3<Float>(3, 3, 3)
        let accumulator = VoxelAccumulator()
        accumulator.record(sample(position, confidence: 0.5, classification: 6)) // window
        accumulator.record(sample(position, confidence: 0.5, classification: 2)) // floor

        let fused = try XCTUnwrap(accumulator.fusedSamples().first)
        XCTAssertEqual(fused.classificationRawValue, 2, "A tied vote must resolve deterministically to the lowest raw value.")
    }

    // MARK: - Deduplication reduces point count on an overlapping scan

    func testFusionMeasurablyReducesPointCountOnOverlappingObservations() {
        // Simulate two neighboring mesh anchors whose boundary vertices
        // overlap: the same ~10x10x10 grid of points, observed twice with
        // slightly different (sub-voxel) jitter, as ARKit re-triangulating
        // a shared edge might produce.
        let accumulator = VoxelAccumulator()
        var totalRecorded = 0
        for anchorPass in 0..<2 {
            let jitter: Float = anchorPass == 0 ? 0.0 : 0.002 // well under one voxel (0.02 m)
            for x in 0..<10 {
                for y in 0..<10 {
                    for z in 0..<10 {
                        let position = SIMD3<Float>(Float(x) * 0.5 + jitter, Float(y) * 0.5 + jitter, Float(z) * 0.5 + jitter)
                        accumulator.record(sample(position, confidence: 0.8))
                        totalRecorded += 1
                    }
                }
            }
        }

        let fusedCount = accumulator.fusedSamples().count
        XCTAssertEqual(totalRecorded, 2000)
        XCTAssertEqual(fusedCount, 1000, "Every duplicated observation must fuse into exactly one point per grid cell.")
        XCTAssertLessThan(fusedCount, totalRecorded, "Fused count must measurably drop versus plain concatenation.")
    }

    // MARK: - Reset / bookkeeping

    func testResetClearsAllObservations() {
        let accumulator = VoxelAccumulator()
        accumulator.record(sample(SIMD3(1, 1, 1), confidence: 0.5))
        XCTAssertEqual(accumulator.observedVoxelCount, 1)

        accumulator.reset()

        XCTAssertEqual(accumulator.observedVoxelCount, 0)
        XCTAssertTrue(accumulator.fusedSamples().isEmpty)
    }

    // MARK: - Incremental withdrawal (Fase 1: audit findings C1/C2)

    func testRemoveExactlyCancelsRecord() throws {
        // A voxel observed three times, one of which is then withdrawn,
        // must be indistinguishable from that voxel having been observed
        // by the other two all along.
        let position = SIMD3<Float>(1, 2, 3)
        let keep = [sample(position, confidence: 0.4), sample(position, confidence: 0.8)]
        let withdrawn = sample(position, confidence: 0.2, color: SIMD3(1, 0, 0), normal: SIMD3(1, 0, 0))

        let incremental = VoxelAccumulator()
        incremental.record(contentsOf: keep)
        incremental.record(withdrawn)
        incremental.remove(withdrawn)

        let baseline = VoxelAccumulator()
        baseline.record(contentsOf: keep)

        let a = try XCTUnwrap(incremental.fusedSamples().first)
        let b = try XCTUnwrap(baseline.fusedSamples().first)
        XCTAssertEqual(a.confidence, b.confidence, accuracy: 0.0001)
        XCTAssertEqual(a.position.x, b.position.x, accuracy: 0.0001)
        XCTAssertEqual(a.color.x, b.color.x, accuracy: 0.0001)
        XCTAssertEqual(a.normal.x, b.normal.x, accuracy: 0.0001)
    }

    func testRemovingTheLastObservationDropsTheVoxelEntirely() {
        // An emptied region must reset exactly, not linger as a cell full
        // of near-cancelled sums that a later observation would average
        // against.
        let accumulator = VoxelAccumulator()
        let only = sample(SIMD3(4, 4, 4), confidence: 0.7)
        accumulator.record(only)
        XCTAssertEqual(accumulator.observedVoxelCount, 1)

        accumulator.remove(only)

        XCTAssertEqual(accumulator.observedVoxelCount, 0)
        XCTAssertTrue(accumulator.fusedSamples().isEmpty)
    }

    func testRemovingAnUnrecordedSampleIsHarmless() {
        let accumulator = VoxelAccumulator()
        accumulator.record(sample(SIMD3(0, 0, 0), confidence: 0.5))
        // A voxel that was never observed at all.
        accumulator.remove(sample(SIMD3(50, 50, 50), confidence: 0.5))
        XCTAssertEqual(accumulator.observedVoxelCount, 1)
    }

    func testRetriangulatedAnchorReplacesItsOwnContributionOnly() throws {
        // The exact scenario the incremental accumulator exists for: two
        // anchors overlap in one voxel; anchor A is re-triangulated, so its
        // old samples are withdrawn and its new ones recorded. Anchor B's
        // contribution must survive untouched, and the result must match a
        // fresh accumulator built from (A-new + B).
        let shared = SIMD3<Float>(2, 0, 0)
        let anchorBSamples = [sample(shared, confidence: 0.6, classification: 1)]
        let anchorAOld = [sample(shared, confidence: 0.2, classification: 2), sample(SIMD3(9, 9, 9), confidence: 0.2)]
        let anchorANew = [sample(shared, confidence: 0.9, classification: 1)]

        let incremental = VoxelAccumulator()
        incremental.record(contentsOf: anchorBSamples)
        incremental.record(contentsOf: anchorAOld)
        incremental.remove(contentsOf: anchorAOld)
        incremental.record(contentsOf: anchorANew)

        let expected = VoxelAccumulator.rebuilt(from: anchorBSamples + anchorANew)

        XCTAssertEqual(incremental.observedVoxelCount, expected.observedVoxelCount,
                       "The stale chunk's isolated voxel must be gone, not stranded.")
        let a = try XCTUnwrap(incremental.fusedSamples().first)
        let b = try XCTUnwrap(expected.fusedSamples().first)
        XCTAssertEqual(a.confidence, b.confidence, accuracy: 0.0001)
        XCTAssertEqual(a.classificationRawValue, b.classificationRawValue)
    }

    func testClassificationVotesAreWithdrawnToo() throws {
        // Two "floor" votes and one "wall"; withdraw one floor and the
        // majority must flip to the tie-break winner, not stay stale.
        let position = SIMD3<Float>(7, 7, 7)
        let accumulator = VoxelAccumulator()
        let floorA = sample(position, confidence: 0.5, classification: 2)
        accumulator.record(floorA)
        accumulator.record(sample(position, confidence: 0.5, classification: 2))
        accumulator.record(sample(position, confidence: 0.5, classification: 1))
        XCTAssertEqual(try XCTUnwrap(accumulator.fusedSamples().first).classificationRawValue, 2)

        accumulator.remove(floorA)

        // Now tied 1-1 — the tie-break rule picks the lowest raw value.
        XCTAssertEqual(try XCTUnwrap(accumulator.fusedSamples().first).classificationRawValue, 1)
    }

    func testUnknownClassificationByteIsNotCounted() throws {
        // A raw value outside ARKit's eight cases must not be tallied at
        // all — it should not silently win, nor be folded into `.none`.
        let position = SIMD3<Float>(8, 8, 8)
        let accumulator = VoxelAccumulator()
        accumulator.record(sample(position, confidence: 0.5, classification: 200))
        accumulator.record(sample(position, confidence: 0.5, classification: 200))
        accumulator.record(sample(position, confidence: 0.5, classification: 3)) // ceiling

        let fused = try XCTUnwrap(accumulator.fusedSamples().first)
        XCTAssertEqual(fused.classificationRawValue, 3, "The only valid vote must win over two unrecognized bytes.")
    }

    func testFusedSamplesAreOrderedDeterministically() {
        // Two accumulators fed the same voxels in opposite order must emit
        // the same sequence — `Dictionary` iteration order is not stable,
        // and an export whose point order shifts between identical scans is
        // needlessly hard to diff.
        let positions = [SIMD3<Float>(3, 0, 0), SIMD3<Float>(0, 0, 0), SIMD3<Float>(-2, 1, 4), SIMD3<Float>(1, 1, 1)]

        let forward = VoxelAccumulator()
        forward.record(contentsOf: positions.map { sample($0, confidence: 0.5) })
        let backward = VoxelAccumulator()
        backward.record(contentsOf: positions.reversed().map { sample($0, confidence: 0.5) })

        XCTAssertEqual(forward.fusedSamples().map(\.position.x), backward.fusedSamples().map(\.position.x))
    }

    func testIncrementalResultMatchesAFullRebuild() throws {
        // The autosave path reads the incremental accumulator; the final
        // export rebuilds. On a scan with overlap and one re-triangulation,
        // the two must agree within float tolerance — otherwise the file
        // the user keeps would differ from what they watched being built.
        var chunkOne: [VoxelAccumulator.Sample] = []
        var chunkTwo: [VoxelAccumulator.Sample] = []
        for i in 0..<200 {
            let x = Float(i) * 0.03
            chunkOne.append(sample(SIMD3(x, 0, 0), confidence: 0.4, classification: 1))
            chunkTwo.append(sample(SIMD3(x + 0.004, 0, 0), confidence: 0.9, classification: 1))
        }

        let incremental = VoxelAccumulator()
        incremental.record(contentsOf: chunkOne)
        incremental.record(contentsOf: chunkTwo)
        incremental.remove(contentsOf: chunkTwo)
        incremental.record(contentsOf: chunkTwo)

        let rebuilt = VoxelAccumulator.rebuilt(from: chunkOne + chunkTwo)

        let a = incremental.fusedSamples()
        let b = rebuilt.fusedSamples()
        XCTAssertEqual(a.count, b.count)
        for (lhs, rhs) in zip(a, b) {
            XCTAssertEqual(lhs.position.x, rhs.position.x, accuracy: 0.001)
            XCTAssertEqual(lhs.confidence, rhs.confidence, accuracy: 0.001)
        }
    }

    // MARK: - Voxel hashing (shared packing scheme)

    func testVoxelKeyGroupsPositionsWithinTheSameCell() {
        let a = SIMD3<Float>(1.001, 2.001, 3.001)
        let b = SIMD3<Float>(1.005, 2.006, 3.004)
        XCTAssertEqual(VoxelAccumulator.voxelKey(for: a), VoxelAccumulator.voxelKey(for: b))
    }

    func testVoxelKeyDistinguishesAdjacentCells() {
        let a = SIMD3<Float>(0, 0, 0)
        let b = SIMD3<Float>(0.05, 0, 0)
        XCTAssertNotEqual(VoxelAccumulator.voxelKey(for: a), VoxelAccumulator.voxelKey(for: b))
    }
}

/// Tests for the pure face-to-vertex majority-vote classification math,
/// exercised with synthetic index/byte arrays rather than a real
/// `ARMeshAnchor` (which has no public initializer usable in a unit test).
final class FaceClassificationVotingTests: XCTestCase {
    func testMajorityVoteAcrossMultipleFacesSharingAVertex() {
        // Three faces all reference vertex 0: two vote "wall" (1), one votes "floor" (2).
        let faces: [(Int, Int, Int)] = [(0, 1, 2), (0, 3, 4), (0, 5, 6)]
        let classifications: [UInt8] = [1, 1, 2]

        let result = FaceClassificationVoting.majorityClassifications(
            faceVertexIndices: faces,
            faceClassificationRawValues: classifications,
            sampledVertexIndices: [0]
        )

        XCTAssertEqual(result[0], 1)
    }

    func testVertexNotReferencedByAnySampledFaceIsAbsentFromTheResult() {
        let faces: [(Int, Int, Int)] = [(1, 2, 3)]
        let classifications: [UInt8] = [1]

        let result = FaceClassificationVoting.majorityClassifications(
            faceVertexIndices: faces,
            faceClassificationRawValues: classifications,
            sampledVertexIndices: [99]
        )

        XCTAssertNil(result[99])
    }

    func testOnlySampledVertexIndicesAreTallied() {
        // Vertex 5 isn't in `sampledVertexIndices` — its votes must not
        // appear in the result at all, even though it's referenced by a face.
        let faces: [(Int, Int, Int)] = [(0, 5, 6)]
        let classifications: [UInt8] = [3]

        let result = FaceClassificationVoting.majorityClassifications(
            faceVertexIndices: faces,
            faceClassificationRawValues: classifications,
            sampledVertexIndices: [0]
        )

        XCTAssertEqual(result[0], 3)
        XCTAssertNil(result[5])
        XCTAssertNil(result[6])
    }

    func testTieBreaksByLowestRawValue() {
        let faces: [(Int, Int, Int)] = [(0, 1, 2), (0, 3, 4)]
        let classifications: [UInt8] = [6, 2] // one vote each — tied

        let result = FaceClassificationVoting.majorityClassifications(
            faceVertexIndices: faces,
            faceClassificationRawValues: classifications,
            sampledVertexIndices: [0]
        )

        XCTAssertEqual(result[0], 2)
    }
}
