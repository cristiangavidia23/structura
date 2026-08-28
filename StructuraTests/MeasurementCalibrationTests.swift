import XCTest

final class MeasurementCalibrationTests: XCTestCase {
    func testMeasuredLongerThanReferenceGivesPositiveSignedError() {
        let result = MeasurementCalibration.evaluate(measuredMeters: 2.10, referenceMeters: 2.00)
        XCTAssertEqual(result.signedErrorMeters, 0.10, accuracy: 0.0001)
        XCTAssertEqual(result.absoluteErrorMeters, 0.10, accuracy: 0.0001)
        XCTAssertEqual(result.errorPercentage ?? -1, 5.0, accuracy: 0.01)
    }

    func testMeasuredShorterThanReferenceGivesNegativeSignedError() {
        let result = MeasurementCalibration.evaluate(measuredMeters: 1.90, referenceMeters: 2.00)
        XCTAssertEqual(result.signedErrorMeters, -0.10, accuracy: 0.0001)
        XCTAssertEqual(result.absoluteErrorMeters, 0.10, accuracy: 0.0001)
        XCTAssertEqual(result.errorPercentage ?? -1, -5.0, accuracy: 0.01)
    }

    func testExactMatchHasZeroError() {
        let result = MeasurementCalibration.evaluate(measuredMeters: 0.9144, referenceMeters: 0.9144) // a standard 36" door
        XCTAssertEqual(result.absoluteErrorMeters, 0, accuracy: 0.0001)
        XCTAssertEqual(result.errorPercentage ?? -1, 0, accuracy: 0.0001)
    }

    func testPercentageIsNilWhenReferenceIsZero() {
        let result = MeasurementCalibration.evaluate(measuredMeters: 1.0, referenceMeters: 0)
        XCTAssertNil(result.errorPercentage)
        XCTAssertEqual(result.absoluteErrorMeters, 1.0, accuracy: 0.0001)
    }
}
