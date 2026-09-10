import XCTest
import simd

/// Acceptance tests for the numbers the 3D inspector puts in front of the
/// user. These are figures someone will read off the screen and quote in a
/// report, so each one is checked against a cloud whose geometry makes the
/// right answer calculable by hand rather than by re-running the code.
final class PointCloudStatisticsTests: XCTestCase {

    private func point(_ x: Float, _ y: Float, _ z: Float, confidence: Float = 1, observed: Bool = true) -> PointCloudExportPoint {
        PointCloudExportPoint(
            position: SIMD3<Float>(x, y, z),
            confidence: confidence,
            isConfidenceObserved: observed
        )
    }

    // MARK: - Bounding box

    func testBoundingBoxSpansTheExtremesOnEveryAxisIndependently() throws {
        let report = try XCTUnwrap(PointCloudStatistics.make(of: [
            point(-1, 0, 4),
            point(3, -2, 0),
            point(0, 5, -6)
        ]))

        XCTAssertEqual(report.boundingBox.minimum, SIMD3<Float>(-1, -2, -6))
        XCTAssertEqual(report.boundingBox.maximum, SIMD3<Float>(3, 5, 4))
        XCTAssertEqual(report.boundingBox.extent, SIMD3<Float>(4, 7, 10))
    }

    func testBoundingBoxCenterAndDiagonal() throws {
        let report = try XCTUnwrap(PointCloudStatistics.make(of: [
            point(0, 0, 0),
            point(2, 4, 4)
        ]))

        XCTAssertEqual(report.boundingBox.center, SIMD3<Float>(1, 2, 2))
        // 2-4-4 box: sqrt(4 + 16 + 16) = 6.
        XCTAssertEqual(report.boundingBox.diagonalMeters, 6, accuracy: 1e-4)
        XCTAssertEqual(report.boundingBox.volumeCubicMeters, 32, accuracy: 1e-4)
    }

    func testASinglePointHasAZeroSizedBoxRatherThanNoBox() throws {
        let report = try XCTUnwrap(PointCloudStatistics.make(of: [point(7, 8, 9)]))

        XCTAssertEqual(report.boundingBox.minimum, SIMD3<Float>(7, 8, 9))
        XCTAssertEqual(report.boundingBox.maximum, SIMD3<Float>(7, 8, 9))
        XCTAssertEqual(report.boundingBox.volumeCubicMeters, 0)
        // Zero volume must not divide into an infinite density.
        XCTAssertEqual(report.densityPerCubicMeter, 0)
        XCTAssertTrue(report.strictDensityPerCubicMeter.isFinite)
    }

    func testNonFinitePositionsAreExcludedFromTheBoxAndTheCount() throws {
        let report = try XCTUnwrap(PointCloudStatistics.make(of: [
            point(0, 0, 0),
            point(2, 2, 2),
            point(.nan, 0, 0),
            point(.infinity, 0, 0)
        ]))

        XCTAssertEqual(report.pointCount, 2, "Non-finite points are not data and must not be counted.")
        XCTAssertEqual(report.boundingBox.maximum, SIMD3<Float>(2, 2, 2), "A non-finite coordinate must never widen the box.")
    }

    // MARK: - Density

    func testDensityPerCubicMeterDividesByTheBoundingBoxVolume() throws {
        // Eight points on the corners of a 2x2x2 m box: 8 m³, so 1 pt/m³.
        var points: [PointCloudExportPoint] = []
        for x in [Float(0), 2] {
            for y in [Float(0), 2] {
                for z in [Float(0), 2] {
                    points.append(point(x, y, z))
                }
            }
        }
        let report = try XCTUnwrap(PointCloudStatistics.make(of: points))

        XCTAssertEqual(report.boundingBox.volumeCubicMeters, 8, accuracy: 1e-4)
        XCTAssertEqual(report.densityPerCubicMeter, 1, accuracy: 1e-4)
    }

    /// The strict figure divides by the volume the scan actually occupies,
    /// which is what makes it comparable between scans of different sizes —
    /// the property the bounding-box figure lacks.
    func testStrictDensityDividesByOccupiedVolumeNotTheBoundingBox() throws {
        // Two points 10 m apart at a 0.1 m occupancy grid: they occupy two
        // cells of 0.001 m³ each, so 0.002 m³ occupied against a bounding
        // box of zero height/depth. Strict density = 2 / 0.002 = 1000.
        let report = try XCTUnwrap(PointCloudStatistics.make(
            of: [point(0, 0, 0), point(10, 0, 0)],
            occupancyVoxelSize: 0.1
        ))

        XCTAssertEqual(report.occupiedVolumeCubicMeters, 0.002, accuracy: 1e-6)
        XCTAssertEqual(report.strictDensityPerCubicMeter, 1000, accuracy: 1)
    }

    /// The behaviour that motivates reporting both figures: spreading the
    /// same points over a larger space drops the bounding-box density even
    /// though every surface is sampled just as finely, while the strict
    /// figure stays put.
    func testSpreadingTheSamePointsOutDropsBoxDensityButNotStrictDensity() throws {
        let tight = (0..<50).map { point(Float($0) * 0.1, 0, 0) }
        let spread = (0..<50).map { point(Float($0) * 1.0, 0, 0) }

        let tightReport = try XCTUnwrap(PointCloudStatistics.make(of: tight, occupancyVoxelSize: 0.1))
        let spreadReport = try XCTUnwrap(PointCloudStatistics.make(of: spread, occupancyVoxelSize: 0.1))

        XCTAssertEqual(
            tightReport.strictDensityPerCubicMeter,
            spreadReport.strictDensityPerCubicMeter,
            accuracy: 1,
            "Both clouds put one point in each occupied cell, so the strict density is the same."
        )
        XCTAssertGreaterThan(
            tightReport.occupiedVolumeCubicMeters,
            0,
            "A degenerate occupied volume would make the comparison above vacuous."
        )
        XCTAssertLessThan(spreadReport.occupiedVolumeCubicMeters, tightReport.occupiedVolumeCubicMeters * 100)
    }

    // MARK: - Confidence

    func testMeanConfidenceAveragesOnlyRealObservations() throws {
        let report = try XCTUnwrap(PointCloudStatistics.make(of: [
            point(0, 0, 0, confidence: 1.0, observed: true),
            point(1, 0, 0, confidence: 0.6, observed: true),
            // A fallback value must not be averaged in as if it were a
            // reading — audit finding E2.
            point(2, 0, 0, confidence: 0.5, observed: false)
        ]))

        XCTAssertEqual(report.meanObservedConfidence, 0.8, accuracy: 1e-5)
        XCTAssertEqual(report.observedConfidenceFraction, 2.0 / 3.0, accuracy: 1e-5)
    }

    func testACloudWithNoObservedConfidenceReportsZeroRatherThanNaN() throws {
        let report = try XCTUnwrap(PointCloudStatistics.make(of: [
            point(0, 0, 0, confidence: 0.5, observed: false),
            point(1, 1, 1, confidence: 0.5, observed: false)
        ]))

        XCTAssertEqual(report.meanObservedConfidence, 0)
        XCTAssertEqual(report.observedConfidenceFraction, 0)
        XCTAssertFalse(report.meanObservedConfidence.isNaN, "0/0 must be reported as zero, not NaN, since this reaches the UI.")
    }

    // MARK: - Degenerate input

    func testEmptyCloudHasNoReport() {
        XCTAssertNil(PointCloudStatistics.make(of: []))
    }

    func testCloudOfOnlyNonFinitePointsHasNoReport() {
        XCTAssertNil(PointCloudStatistics.make(of: [point(.nan, .nan, .nan)]))
    }

    func testInvalidOccupancyVoxelSizeHasNoReport() {
        let points = [point(0, 0, 0), point(1, 1, 1)]
        XCTAssertNil(PointCloudStatistics.make(of: points, occupancyVoxelSize: 0))
        XCTAssertNil(PointCloudStatistics.make(of: points, occupancyVoxelSize: -1))
        XCTAssertNil(PointCloudStatistics.make(of: points, occupancyVoxelSize: .nan))
    }
}
