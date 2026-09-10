import simd
import XCTest

/// Numeric acceptance tests for `ConfidenceGrid` — the Fase 2 verification
/// plan calls for a test proving the grid averages repeated observations of
/// the same voxel correctly, plus coverage of its voxel-hashing scheme
/// (shared, by design, with `PointCloudStore`'s existing packing).
final class ConfidenceGridTests: XCTestCase {

    func testRecordAveragesRepeatedObservationsInTheSameVoxel() throws {
        let grid = ConfidenceGrid()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)

        grid.record(position: position, confidence: 0.3)
        grid.record(position: position, confidence: 0.9)

        let confidence = try XCTUnwrap(grid.confidence(at: position))
        XCTAssertEqual(confidence, 0.6, accuracy: 0.0001)
    }

    func testRecordWeightsByObservationCountNotJustLastSample() throws {
        let grid = ConfidenceGrid()
        let position = SIMD3<Float>(0, 0, 0)

        grid.record(position: position, confidence: 1.0)
        grid.record(position: position, confidence: 1.0)
        grid.record(position: position, confidence: 0.0) // a single low sample shouldn't dominate

        let confidence = try XCTUnwrap(grid.confidence(at: position))
        XCTAssertEqual(confidence, 2.0 / 3.0, accuracy: 0.0001)
    }

    func testConfidenceIsNilForAnUnobservedVoxel() {
        let grid = ConfidenceGrid()
        XCTAssertNil(grid.confidence(at: SIMD3<Float>(5, 5, 5)))
    }

    func testResetClearsAllObservations() {
        let grid = ConfidenceGrid()
        let position = SIMD3<Float>(1, 1, 1)
        grid.record(position: position, confidence: 0.8)
        XCTAssertNotNil(grid.confidence(at: position))

        grid.reset()

        XCTAssertNil(grid.confidence(at: position))
        XCTAssertEqual(grid.observedVoxelCount, 0)
    }

    func testObservedVoxelCountCountsDistinctVoxelsNotSamples() {
        let grid = ConfidenceGrid()
        let position = SIMD3<Float>(2, 2, 2)
        grid.record(position: position, confidence: 0.5)
        grid.record(position: position, confidence: 0.7) // same voxel, second sample
        grid.record(position: SIMD3<Float>(50, 50, 50), confidence: 0.5) // a different voxel

        XCTAssertEqual(grid.observedVoxelCount, 2)
    }

    // MARK: - Thread-safety (Fase 1: audit finding C4's consequence for this type)

    /// `record` is called from `ARPointCloudSession.processFrame`'s queue
    /// and `confidence(at:)` from `processMeshAnchor`'s — two different
    /// queues since Fase 1 split mesh processing off the delegate queue.
    /// This doesn't prove the absence of every possible race, but it does
    /// exercise the lock under real concurrent pressure: without it (or
    /// with it implemented wrong), an unsynchronized read-modify-write on
    /// `cells[key]` would be expected to lose some observations under this
    /// much contention, not just occasionally skew the average slightly.
    func testConcurrentRecordsFromMultipleQueuesDoNotLoseObservations() throws {
        let grid = ConfidenceGrid()
        let position = SIMD3<Float>(3, 3, 3)
        let iterationsPerQueue = 500

        let queueA = DispatchQueue(label: "test.confidencegrid.a")
        let queueB = DispatchQueue(label: "test.confidencegrid.b")
        let group = DispatchGroup()

        group.enter()
        queueA.async {
            for _ in 0..<iterationsPerQueue { grid.record(position: position, confidence: 1.0) }
            group.leave()
        }
        group.enter()
        queueB.async {
            for _ in 0..<iterationsPerQueue { grid.record(position: position, confidence: 0.0) }
            group.leave()
        }
        group.wait()

        // Every observation landed — none lost to an unsynchronized
        // read-modify-write — so the average must be exactly the midpoint
        // regardless of how the two queues interleaved.
        let confidence = try XCTUnwrap(grid.confidence(at: position))
        XCTAssertEqual(confidence, 0.5, accuracy: 0.0001)
    }

    // MARK: - Voxel hashing

    func testVoxelKeyGroupsPositionsWithinTheSameCell() {
        // Both positions round to the same cell at `ProScanConfig.voxelSizeMeters`
        // (0.02 m) resolution — well within half a voxel of each other.
        let a = SIMD3<Float>(1.001, 2.001, 3.001)
        let b = SIMD3<Float>(1.005, 2.006, 3.004)
        XCTAssertEqual(ConfidenceGrid.voxelKey(for: a), ConfidenceGrid.voxelKey(for: b))
    }

    func testVoxelKeyDistinguishesAdjacentCells() {
        let a = SIMD3<Float>(0, 0, 0)
        let b = SIMD3<Float>(0.05, 0, 0) // more than one voxel away in X
        XCTAssertNotEqual(ConfidenceGrid.voxelKey(for: a), ConfidenceGrid.voxelKey(for: b))
    }

    func testVoxelKeyDistinguishesEachAxisIndependently() {
        let origin = SIMD3<Float>(0, 0, 0)
        let shiftedX = SIMD3<Float>(0.5, 0, 0)
        let shiftedY = SIMD3<Float>(0, 0.5, 0)
        let shiftedZ = SIMD3<Float>(0, 0, 0.5)

        let keys = [origin, shiftedX, shiftedY, shiftedZ].map(ConfidenceGrid.voxelKey(for:))
        XCTAssertEqual(Set(keys).count, 4, "Shifting along any single axis must change the packed key.")
    }

    func testVoxelKeyIsSymmetricAroundTheOrigin() {
        // The packing scheme masks to 20 unsigned bits per axis after
        // rounding — verifies negative coordinates (common once a scan's
        // origin isn't at a room corner) don't collide with unrelated
        // positive ones near the wraparound boundary of that mask.
        let negative = SIMD3<Float>(-1.0, -2.0, -3.0)
        let positive = SIMD3<Float>(1.0, 2.0, 3.0)
        XCTAssertNotEqual(ConfidenceGrid.voxelKey(for: negative), ConfidenceGrid.voxelKey(for: positive))

        // Round-trip sanity: two samples very close to the same negative
        // coordinate must still land in the same voxel.
        let nearNegative = SIMD3<Float>(-1.001, -2.002, -3.003)
        XCTAssertEqual(ConfidenceGrid.voxelKey(for: negative), ConfidenceGrid.voxelKey(for: nearNegative))
    }
}
