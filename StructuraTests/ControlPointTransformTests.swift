import simd
import XCTest

/// `ControlPointTransform` is translation-only by design (see its doc
/// comment for why a single control point can't also determine rotation)
/// — these tests confirm exactly that: the offset is derived correctly,
/// and applying it never introduces any rotation/scaling.
final class ControlPointTransformTests: XCTestCase {
    func testAppliesTheCorrectTranslationOffset() {
        let transform = ControlPointTransform(
            measuredLocalPosition: SIMD3<Float>(10, 5, 2),
            knownRealCoordinate: SIMD3<Float>(1000, 2000, 50),
            declaredAccuracyMeters: 0.02
        )

        // The control point itself must map exactly onto its known
        // real-world coordinate.
        let mapped = transform.apply(transform.measuredLocalPosition)
        XCTAssertEqual(mapped, transform.knownRealCoordinate)
    }

    func testTranslatesOtherPointsByTheSameOffset() {
        let transform = ControlPointTransform(
            measuredLocalPosition: SIMD3<Float>(0, 0, 0),
            knownRealCoordinate: SIMD3<Float>(100, 200, 10),
            declaredAccuracyMeters: nil
        )

        let nearbyPoint = SIMD3<Float>(1, 2, 3)
        let transformed = transform.apply(nearbyPoint)

        XCTAssertEqual(transformed, SIMD3<Float>(101, 202, 13))
    }

    func testIsAPureTranslationNoRotationOrScaling() {
        let transform = ControlPointTransform(
            measuredLocalPosition: SIMD3<Float>(5, 5, 5),
            knownRealCoordinate: SIMD3<Float>(500, 500, 500),
            declaredAccuracyMeters: nil
        )

        let a = SIMD3<Float>(0, 0, 0)
        let b = SIMD3<Float>(3, 4, 0)
        let distanceBefore = simd_distance(a, b)
        let distanceAfter = simd_distance(transform.apply(a), transform.apply(b))

        XCTAssertEqual(distanceBefore, distanceAfter, accuracy: 0.0001, "A translation must preserve distances between points exactly.")
    }
}
