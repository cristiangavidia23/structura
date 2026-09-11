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

 
 
 
    /// The depth path cannot label points — ARKit classifies mesh faces, not
    /// depth pixels, so those samples carry `.none`. Where the mesh path did
    /// observe the same voxel, its real label has to survive the merge
    /// rather than be outvoted into "unclassified".
 
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

 
    // MARK: - Casos degenerados

 
    /// A scan running before the mesh path has produced anything (or on a
    /// surface ARKit declines to reconstruct) must still export the depth
    /// cloud, not nothing.
 
    // MARK: - Adaptación térmica de la ingesta de profundidad

    // MARK: - Orden de salida

    /// The autosave path skips sorting to keep `meshLock` short. Skipping it
    /// must change only the order, never the contents — an autosaved file is
    /// a real crash-recovery snapshot, not a lossy preview.
    func testSkippingTheSortChangesOrderButNotContents() {
        let accumulator = VoxelAccumulator()
        for i in 0..<200 {
            accumulator.record(sample(Float(i) * 0.05, Float(i % 7) * 0.05, Float(i % 3) * 0.05))
        }

        let sorted = accumulator.fusedSamples(sorted: true)
        let unsorted = accumulator.fusedSamples(sorted: false)

        XCTAssertEqual(sorted.count, unsorted.count)
        func key(_ s: VoxelAccumulator.Sample) -> String {
            String(format: "%.4f/%.4f/%.4f", s.position.x, s.position.y, s.position.z)
        }
        XCTAssertEqual(Set(sorted.map(key)), Set(unsorted.map(key)))
    }

    func testSortedOutputIsStableAcrossCalls() {
        let accumulator = VoxelAccumulator()
        for i in 0..<100 {
            accumulator.record(sample(Float(i) * 0.07, 0, Float(i % 5) * 0.03))
        }

        let first = accumulator.fusedSamples(sorted: true).map(\.position.x)
        let second = accumulator.fusedSamples(sorted: true).map(\.position.x)

        XCTAssertEqual(first, second, "A deterministic order is the whole reason the export pays for the sort.")
    }

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
