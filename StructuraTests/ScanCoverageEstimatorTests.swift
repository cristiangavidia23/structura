import simd
import XCTest

final class ScanCoverageEstimatorTests: XCTestCase {
    private func point(_ position: SIMD3<Float>) -> PointCloudExportPoint {
        PointCloudExportPoint(position: position, confidence: 1.0)
    }

    func testFullyDensePointsReportFullCoverage() throws {
        let voxelSize: Float = 0.1
        var points: [PointCloudExportPoint] = []
        for x in 0..<5 {
            for y in 0..<5 {
                points.append(point(SIMD3(Float(x) * voxelSize, Float(y) * voxelSize, 0)))
            }
        }
        let report = try XCTUnwrap(ScanCoverageEstimator.estimateCoverage(of: points, voxelSize: voxelSize))
        XCTAssertEqual(report.coverageRatio, 1.0, accuracy: 0.01)
    }

    func testSparsePointsReportPartialCoverage() throws {
        let voxelSize: Float = 0.1
        // Only the four corners of a 10x10-cell bounding box are occupied.
        let points = [
            point(SIMD3(0, 0, 0)),
            point(SIMD3(0.9, 0, 0)),
            point(SIMD3(0, 0.9, 0)),
            point(SIMD3(0.9, 0.9, 0)),
        ]
        let report = try XCTUnwrap(ScanCoverageEstimator.estimateCoverage(of: points, voxelSize: voxelSize))
        XCTAssertLessThan(report.coverageRatio, 0.1, "Four occupied corners of a much larger bounding box must report low coverage.")
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(ScanCoverageEstimator.estimateCoverage(of: [], voxelSize: 0.1))
    }

    func testNonFinitePositionsAreSkippedRatherThanCrashing() throws {
        let points = [
            point(SIMD3(Float.nan, 0, 0)),
            point(SIMD3(.infinity, 0, 0)),
            point(SIMD3(0, 0, 0)),
            point(SIMD3(0.1, 0, 0)),
        ]
        let report = try XCTUnwrap(ScanCoverageEstimator.estimateCoverage(of: points, voxelSize: 0.1))
        XCTAssertGreaterThan(report.coverageRatio, 0, "The two finite points must still be counted despite the non-finite ones.")
    }

    func testZeroOrInvalidVoxelSizeReturnsNil() {
        let points = [point(SIMD3(0, 0, 0))]
        XCTAssertNil(ScanCoverageEstimator.estimateCoverage(of: points, voxelSize: 0))
        XCTAssertNil(ScanCoverageEstimator.estimateCoverage(of: points, voxelSize: -1))
    }
}
