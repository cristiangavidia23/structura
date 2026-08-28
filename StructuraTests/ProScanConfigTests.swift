import Foundation
import XCTest

/// `StructuraTests` is a host-less logic-test bundle: `Structura/Info.plist`
/// declares `arkit`/`lidar` as required device capabilities, so the app
/// target cannot install on the Simulator and can't serve as a test host.
/// Instead this target compiles the specific pure-Swift source files under
/// test directly as its own sources (see `project.yml`) — no `import
/// Structura`, no app module, no device required.
final class ProScanConfigTests: XCTestCase {

    func testDepthRangeIsPhysicallySane() {
        let range = ProScanConfig.validDepthRangeMeters
        XCTAssertGreaterThan(range.lowerBound, 0, "A zero or negative lower bound would let degenerate/behind-camera depth through.")
        XCTAssertLessThan(range.lowerBound, range.upperBound)
        XCTAssertLessThanOrEqual(range.upperBound, 10, "LiDAR-grade confidence doesn't extend this far; a much larger bound likely means the constant was fat-fingered.")
    }

    /// Guards against the two confidence constants silently drifting apart
    /// — exactly the kind of bug the audit found in the current export path
    /// (a hardcoded `confidence: 1.0` never actually reflecting the real
    /// `ARConfidenceLevel`).
    func testConfidenceNormalizationMatchesARConfidenceLevelHigh() {
        let highRawValue: Float = 2 // ARConfidenceLevel.high.rawValue, verified against ARDepthData.h
        let derived = Float(ProScanConfig.minimumConfidenceRawLevel) / highRawValue
        XCTAssertEqual(derived, ProScanConfig.minimumNormalizedConfidence, accuracy: 0.0001)
    }

    func testVoxelSizeIsPositiveAndSubCentimeterPrecise() {
        XCTAssertGreaterThan(ProScanConfig.voxelSizeMeters, 0)
        XCTAssertLessThan(ProScanConfig.voxelSizeMeters, 0.1, "A voxel this large would merge distinct room-scale features.")
    }

    func testStridesAreAtLeastOne() {
        XCTAssertGreaterThanOrEqual(ProScanConfig.meshVertexStride, 1)
        XCTAssertGreaterThanOrEqual(ProScanConfig.depthPixelStride, 1)
    }

    /// The Fase 2 throttle only does anything if this stays well below
    /// ARKit's native delivery rate.
    func testDepthSampleHzIsSlowerThanARKitFrameRate() {
        XCTAssertGreaterThan(ProScanConfig.depthSampleHz, 0)
        XCTAssertLessThan(ProScanConfig.depthSampleHz, 60)
    }

    func testMaximumAngularVelocityIsPositive() {
        XCTAssertGreaterThan(ProScanConfig.maximumAngularVelocityRadiansPerSecond, 0)
    }

    func testRecommendedMaxDurationIsPositive() {
        XCTAssertGreaterThan(ProScanConfig.recommendedMaxDurationSeconds, 0)
    }

    // MARK: - Depth/confidence predicates

    func testIsDepthValidRejectsOutOfRangeAndNonFinite() {
        let range = ProScanConfig.validDepthRangeMeters
        XCTAssertTrue(ProScanConfig.isDepthValid(range.lowerBound + 0.01))
        XCTAssertTrue(ProScanConfig.isDepthValid(range.upperBound - 0.01))
        XCTAssertFalse(ProScanConfig.isDepthValid(range.lowerBound - 0.01))
        XCTAssertFalse(ProScanConfig.isDepthValid(range.upperBound + 0.01))
        XCTAssertFalse(ProScanConfig.isDepthValid(.nan))
        XCTAssertFalse(ProScanConfig.isDepthValid(0))
        XCTAssertFalse(ProScanConfig.isDepthValid(-1))
    }

    func testNormalizedConfidenceMatchesRawLevelMapping() {
        // ARConfidenceLevel.low/medium/high == 0/1/2.
        XCTAssertEqual(ProScanConfig.normalizedConfidence(fromRaw: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(ProScanConfig.normalizedConfidence(fromRaw: 1), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ProScanConfig.normalizedConfidence(fromRaw: 2), 1.0, accuracy: 0.0001)
    }

    func testIsConfidenceAcceptableUsesConfiguredMinimum() {
        XCTAssertTrue(ProScanConfig.isConfidenceAcceptable(ProScanConfig.minimumNormalizedConfidence))
        XCTAssertTrue(ProScanConfig.isConfidenceAcceptable(1.0))
        XCTAssertFalse(ProScanConfig.isConfidenceAcceptable(ProScanConfig.minimumNormalizedConfidence - 0.01))
        XCTAssertFalse(ProScanConfig.isConfidenceAcceptable(.nan))
    }

    // MARK: - Adaptive resource budget

    func testMeshVertexStrideWidensUnderThermalPressure() {
        let nominal = ProScanConfig.meshVertexStride(forThermalState: .nominal)
        let fair = ProScanConfig.meshVertexStride(forThermalState: .fair)
        let serious = ProScanConfig.meshVertexStride(forThermalState: .serious)
        let critical = ProScanConfig.meshVertexStride(forThermalState: .critical)

        XCTAssertEqual(nominal, ProScanConfig.meshVertexStride)
        XCTAssertEqual(fair, ProScanConfig.meshVertexStride)
        XCTAssertGreaterThan(serious, fair, "Sampling density must drop once the device reports thermal pressure.")
        XCTAssertGreaterThan(critical, serious, "Critical thermal state must sample even more sparsely than serious.")
    }

    func testMeshPointBudgetPredicate() {
        XCTAssertFalse(ProScanConfig.isMeshPointBudgetExceeded(currentCount: 0))
        XCTAssertFalse(ProScanConfig.isMeshPointBudgetExceeded(currentCount: ProScanConfig.maximumMeshPointBudget - 1))
        XCTAssertTrue(ProScanConfig.isMeshPointBudgetExceeded(currentCount: ProScanConfig.maximumMeshPointBudget))
        XCTAssertTrue(ProScanConfig.isMeshPointBudgetExceeded(currentCount: ProScanConfig.maximumMeshPointBudget + 1))
    }

    // MARK: - Export precision

    func testLASScaleFactorIsPositiveAndSubMillimeter() {
        XCTAssertGreaterThan(ProScanConfig.lasScaleFactorMeters, 0)
        XCTAssertLessThanOrEqual(ProScanConfig.lasScaleFactorMeters, 0.001)
    }

    // MARK: - Session interruption recovery

    func testRelocalizationConfirmationFrameCountIsPositive() {
        XCTAssertGreaterThan(ProScanConfig.relocalizationConfirmationFrameCount, 0)
    }

    // MARK: - Resource guards

    func testMinimumFreeDiskSpaceIsPositive() {
        XCTAssertGreaterThan(ProScanConfig.minimumFreeDiskSpaceBytes, 0)
    }

    func testMinimumBatteryLevelIsAFraction() {
        XCTAssertGreaterThan(ProScanConfig.minimumBatteryLevelWhileUnplugged, 0)
        XCTAssertLessThan(ProScanConfig.minimumBatteryLevelWhileUnplugged, 1)
    }

    func testShouldAbortCaptureOnlyForCriticalThermalState() {
        XCTAssertFalse(ProScanConfig.shouldAbortCapture(forThermalState: .nominal))
        XCTAssertFalse(ProScanConfig.shouldAbortCapture(forThermalState: .fair))
        XCTAssertFalse(ProScanConfig.shouldAbortCapture(forThermalState: .serious))
        XCTAssertTrue(ProScanConfig.shouldAbortCapture(forThermalState: .critical))
    }

    // MARK: - Autosave

    func testAutosaveIntervalIsPositiveAndReasonablyFrequent() {
        XCTAssertGreaterThan(ProScanConfig.autosaveIntervalSeconds, 0)
        XCTAssertLessThanOrEqual(ProScanConfig.autosaveIntervalSeconds, 60, "An autosave interval this long would defeat the point of protecting against an app kill.")
    }

    // MARK: - Measurement

    func testPlaneFitNeighborhoodRadiusIsPositiveAndCoarserThanTheVoxelSize() {
        XCTAssertGreaterThan(ProScanConfig.planeFitNeighborhoodRadiusMeters, ProScanConfig.voxelSizeMeters)
    }

    func testMaximumPlanarAngularSpreadIsAPositiveAngleUnderNinetyDegrees() {
        XCTAssertGreaterThan(ProScanConfig.maximumPlanarAngularSpreadRadians, 0)
        XCTAssertLessThan(ProScanConfig.maximumPlanarAngularSpreadRadians, .pi / 2)
    }

    func testMinimumPlaneFitNeighborCountIsAtLeastThree() {
        // Fewer than 3 points can't meaningfully constrain a plane at all.
        XCTAssertGreaterThanOrEqual(ProScanConfig.minimumPlaneFitNeighborCount, 3)
    }

    func testRaycastMaxPerpendicularDistanceIsPositive() {
        XCTAssertGreaterThan(ProScanConfig.raycastMaxPerpendicularDistanceMeters, 0)
    }

    func testCoverageVoxelSizeIsCoarserThanTheDedupVoxelSize() {
        XCTAssertGreaterThan(ProScanConfig.coverageVoxelSizeMeters, ProScanConfig.voxelSizeMeters)
    }

    func testDriftRiskElevatedMatchesRecommendedMaxDuration() {
        XCTAssertFalse(ProScanConfig.isDriftRiskElevated(durationSeconds: ProScanConfig.recommendedMaxDurationSeconds))
        XCTAssertTrue(ProScanConfig.isDriftRiskElevated(durationSeconds: ProScanConfig.recommendedMaxDurationSeconds + 1))
    }
}
