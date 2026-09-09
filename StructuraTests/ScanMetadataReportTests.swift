import simd
import XCTest

/// Acceptance tests for `ScanMetadataReport.make(...)`'s confidence
/// accounting — Fase 2 of the architecture audit, finding E2. Before this
/// phase, `meanConfidence` silently averaged in every fallback-confidence
/// point alongside real ones; these tests pin down the corrected behavior:
/// the mean covers only real observations, and
/// `unobservedConfidencePointFraction` reports what fraction of the export
/// that average does *not* speak for.
final class ScanMetadataReportTests: XCTestCase {

    private func point(confidence: Float, isConfidenceObserved: Bool, x: Float = 0, z: Float = 0) -> PointCloudExportPoint {
        PointCloudExportPoint(
            position: SIMD3<Float>(x, 0, z), confidence: confidence, isConfidenceObserved: isConfidenceObserved
        )
    }

    func testMeanConfidenceExcludesUnobservedPoints() {
        let points = [
            point(confidence: 1.0, isConfidenceObserved: true),
            point(confidence: 0.8, isConfidenceObserved: true),
            // A fallback value far from the two real ones above — if this
            // were still included, it would pull the mean noticeably away
            // from 0.9.
            point(confidence: 0.5, isConfidenceObserved: false),
        ]
        let report = ScanMetadataReport.make(
            points: points,
            metadata: PointCloudExportMetadata(capturedAt: Date(), location: nil, pointCount: points.count),
            durationSeconds: 30,
            trackingDegradedTickCount: 0,
            coordinateReferenceSystem: "local"
        )
        XCTAssertEqual(report.meanConfidence, 0.9, accuracy: 0.001)
    }

    func testUnobservedConfidencePointFractionCountsCorrectly() {
        let points = [
            point(confidence: 1.0, isConfidenceObserved: true),
            point(confidence: 0.5, isConfidenceObserved: false),
            point(confidence: 0.5, isConfidenceObserved: false),
            point(confidence: 0.5, isConfidenceObserved: false),
        ]
        let report = ScanMetadataReport.make(
            points: points,
            metadata: PointCloudExportMetadata(capturedAt: Date(), location: nil, pointCount: points.count),
            durationSeconds: 30,
            trackingDegradedTickCount: 0,
            coordinateReferenceSystem: "local"
        )
        XCTAssertEqual(report.unobservedConfidencePointFraction, 0.75, accuracy: 0.001)
    }

    func testMeanConfidenceIsZeroWhenNoPointHasARealObservation() {
        let points = [
            point(confidence: 0.5, isConfidenceObserved: false),
            point(confidence: 0.5, isConfidenceObserved: false),
        ]
        let report = ScanMetadataReport.make(
            points: points,
            metadata: PointCloudExportMetadata(capturedAt: Date(), location: nil, pointCount: points.count),
            durationSeconds: 30,
            trackingDegradedTickCount: 0,
            coordinateReferenceSystem: "local"
        )
        XCTAssertEqual(report.meanConfidence, 0)
        XCTAssertEqual(report.unobservedConfidencePointFraction, 1.0, accuracy: 0.001)
    }

    func testEmptyPointCloudReportsZeroForBothFields() {
        let report = ScanMetadataReport.make(
            points: [],
            metadata: PointCloudExportMetadata(capturedAt: Date(), location: nil, pointCount: 0),
            durationSeconds: 0,
            trackingDegradedTickCount: 0,
            coordinateReferenceSystem: "local"
        )
        XCTAssertEqual(report.meanConfidence, 0)
        XCTAssertEqual(report.unobservedConfidencePointFraction, 0)
    }

    func testAllPointsObservedMeansZeroUnobservedFraction() {
        let points = [
            point(confidence: 0.6, isConfidenceObserved: true),
            point(confidence: 0.9, isConfidenceObserved: true),
        ]
        let report = ScanMetadataReport.make(
            points: points,
            metadata: PointCloudExportMetadata(capturedAt: Date(), location: nil, pointCount: points.count),
            durationSeconds: 30,
            trackingDegradedTickCount: 0,
            coordinateReferenceSystem: "local"
        )
        XCTAssertEqual(report.unobservedConfidencePointFraction, 0)
        XCTAssertEqual(report.meanConfidence, 0.75, accuracy: 0.001)
    }
}
