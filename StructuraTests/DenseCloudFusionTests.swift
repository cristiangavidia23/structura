import XCTest
import simd

/// Covers the change that made Pro Scan's exported cloud dense: folding the
/// LiDAR depth map into the accumulator alongside ARKit's scene mesh, and
/// fusing the two sources into one cloud.
///
/// The failure this guards against is subtle and would look like *success*
/// on the HUD — two sources observing the same room, concatenated, report
/// twice the points while describing the same surfaces at the same
/// resolution. A denser-looking number for no more real geometry is exactly
/// the kind of fabricated precision this project avoids elsewhere.
final class DenseCloudFusionTests: XCTestCase {

    private func sample(
        _ x: Float, _ y: Float, _ z: Float,
        confidence: Float = 1,
        color: SIMD3<Float> = SIMD3<Float>(1, 1, 1),
        normal: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
        classification: UInt8 = 0,
        observed: Bool = true
    ) -> VoxelAccumulator.Sample {
        VoxelAccumulator.Sample(
            position: SIMD3<Float>(x, y, z),
            confidence: confidence,
            color: color,
            normal: normal,
            classificationRawValue: classification,
            isConfidenceObserved: observed
        )
    }

    // MARK: - Fusión de las dos fuentes

    func testMergingCollapsesPointsTheTwoSourcesBothObserved() {
        // Same physical spot, seen by the mesh path and the depth path.
        let mesh = [sample(1, 1, 1)]
        let depth = [sample(1, 1, 1)]

        let merged = VoxelAccumulator.merged(mesh, depth)

        XCTAssertEqual(merged.count, 1, "A voxel both sources saw is one point, not two coincident ones.")
    }

    func testMergingKeepsGeometryOnlyOneSourceSaw() {
        // The depth map reaches surfaces ARKit's mesh never reconstructed;
        // that extra coverage is the whole point of ingesting it.
        let mesh = [sample(0, 0, 0)]
        let depth = [sample(0, 0, 0), sample(5, 0, 0), sample(0, 5, 0)]

        let merged = VoxelAccumulator.merged(mesh, depth)

        XCTAssertEqual(merged.count, 3)
    }

    func testMergingIsNotAffectedByArgumentOrder() {
        let mesh = [sample(0, 0, 0, confidence: 1), sample(2, 0, 0, confidence: 0.6)]
        let depth = [sample(0, 0, 0, confidence: 0.5), sample(9, 9, 9)]

        let forward = VoxelAccumulator.merged(mesh, depth)
        let backward = VoxelAccumulator.merged(depth, mesh)

        XCTAssertEqual(forward.count, backward.count)
        for (a, b) in zip(forward, backward) {
            XCTAssertEqual(a.position.x, b.position.x, accuracy: 1e-5)
            XCTAssertEqual(a.position.y, b.position.y, accuracy: 1e-5)
            XCTAssertEqual(a.position.z, b.position.z, accuracy: 1e-5)
            XCTAssertEqual(a.confidence, b.confidence, accuracy: 1e-5)
        }
    }

    /// The depth path cannot label points — ARKit classifies mesh faces, not
    /// depth pixels, so those samples carry `.none`. Where the mesh path did
    /// observe the same voxel, its real label has to survive the merge
    /// rather than be outvoted into "unclassified".
    func testAMeshClassificationSurvivesMergingWithUnlabelledDepthPoints() {
        let wallCode: UInt8 = 3
        let mesh = [sample(1, 1, 1, classification: wallCode)]
        let depth = [sample(1, 1, 1, classification: VoxelAccumulator.unclassifiedRawValue)]

        let merged = VoxelAccumulator.merged(mesh, depth)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(
            merged[0].classificationRawValue, wallCode,
            "A real classification observed by one source must not be lost to an unlabelled duplicate."
        )
    }

    /// The production shape of the previous test: the depth path is far
    /// denser than the mesh path, so if its samples voted at all they would
    /// win by sheer count. This is the case that would have silently
    /// stripped the semantic labels out of every LAS export.
    func testManyUnlabelledDepthPointsCannotOutvoteOneRealClassification() {
        let doorCode: UInt8 = 5
        let accumulator = VoxelAccumulator()
        accumulator.record(sample(1, 1, 1, classification: doorCode))
        for _ in 0..<500 {
            accumulator.record(sample(1, 1, 1, classification: VoxelAccumulator.unclassifiedRawValue))
        }

        let fused = accumulator.fusedSamples()

        XCTAssertEqual(fused.count, 1)
        XCTAssertEqual(fused[0].classificationRawValue, doorCode)
    }

    /// A voxel only the depth path ever saw has genuinely no label, and must
    /// report `.none` rather than the sentinel leaking into the export.
    func testAVoxelWithNoClassificationOpinionReportsNone() {
        let accumulator = VoxelAccumulator()
        for _ in 0..<10 {
            accumulator.record(sample(2, 2, 2, classification: VoxelAccumulator.unclassifiedRawValue))
        }

        let fused = accumulator.fusedSamples()

        XCTAssertEqual(fused.count, 1)
        XCTAssertEqual(fused[0].classificationRawValue, 0, "The sentinel must never reach an exported point.")
    }

    func testMergedConfidenceIsWeightedAcrossBothSources() {
        let mesh = [sample(0, 0, 0, confidence: 1.0)]
        let depth = [sample(0, 0, 0, confidence: 0.5)]

        let merged = VoxelAccumulator.merged(mesh, depth)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].confidence, 0.75, accuracy: 1e-5, "Two observations of one voxel average.")
    }

    // MARK: - Casos degenerados

    func testMergingWithAnEmptySideReturnsTheOtherUntouched() {
        let points = [sample(1, 2, 3), sample(4, 5, 6)]

        XCTAssertEqual(VoxelAccumulator.merged(points, []).count, 2)
        XCTAssertEqual(VoxelAccumulator.merged([], points).count, 2)
        XCTAssertTrue(VoxelAccumulator.merged([], []).isEmpty)
    }

    /// A scan running before the mesh path has produced anything (or on a
    /// surface ARKit declines to reconstruct) must still export the depth
    /// cloud, not nothing.
    func testDepthOnlyCloudSurvivesTheMerge() {
        let depth = (0..<50).map { sample(Float($0) * 0.5, 0, 0) }

        let merged = VoxelAccumulator.merged([], depth)

        XCTAssertEqual(merged.count, 50)
    }

    // MARK: - Adaptación térmica de la ingesta de profundidad

    func testDepthStrideWidensUnderThermalPressureAndNeverNarrows() {
        let nominal = ProScanConfig.depthPixelStride(forThermalState: .nominal)
        let fair = ProScanConfig.depthPixelStride(forThermalState: .fair)
        let serious = ProScanConfig.depthPixelStride(forThermalState: .serious)
        let critical = ProScanConfig.depthPixelStride(forThermalState: .critical)

        XCTAssertEqual(nominal, ProScanConfig.depthPixelStride)
        XCTAssertEqual(fair, nominal, "Fair is not yet thermal pressure worth degrading capture for.")
        XCTAssertGreaterThan(serious, fair)
        XCTAssertGreaterThan(critical, serious)
        // A stride below 1 would loop forever on the same pixel.
        XCTAssertGreaterThanOrEqual(nominal, 1)
    }

    /// The depth path is the dense one, so its budget has to be expressed in
    /// voxels (what it actually retains) rather than in raw observations.
    func testDepthVoxelBudgetIsLargeEnoughForARoomScaleScan() {
        // A 2 cm voxel grid over ~100 m² of surface is on the order of
        // 250k voxels; the ceiling must comfortably clear that or a normal
        // room would stop accumulating partway through.
        XCTAssertGreaterThan(ProScanConfig.maximumDepthVoxelCount, 250_000)
    }
}
