import simd
import XCTest

final class TopographicAxisConventionTests: XCTestCase {
    func testUpBecomesZ() {
        let up = SIMD3<Float>(0, 1, 0) // ARKit "up"
        let converted = TopographicAxisConvention.convert(up)
        XCTAssertEqual(converted, SIMD3<Float>(0, 0, 1))
    }

    func testXIsUnchanged() {
        let point = SIMD3<Float>(5, 2, 3)
        let converted = TopographicAxisConvention.convert(point)
        XCTAssertEqual(converted.x, 5)
    }

    func testConversionPreservesHandedness() {
        // The 3x3 rotation matrix (x, y, z) -> (x, -z, y) must have
        // determinant +1 — a proper rotation, not a mirror/reflection.
        // Verified here via the standard basis vectors rather than by
        // reading the implementation, so a sign-flip bug (e.g. writing
        // (x, z, y), a reflection) would fail this test.
        let ex = TopographicAxisConvention.convert(SIMD3<Float>(1, 0, 0))
        let ey = TopographicAxisConvention.convert(SIMD3<Float>(0, 1, 0))
        let ez = TopographicAxisConvention.convert(SIMD3<Float>(0, 0, 1))
        let matrix = simd_float3x3(ex, ey, ez) // columns
        XCTAssertEqual(simd_determinant(matrix), 1.0, accuracy: 0.0001)
    }

    func testConversionIsALengthPreservingIsometry() {
        let point = SIMD3<Float>(3, -4, 5)
        let converted = TopographicAxisConvention.convert(point)
        XCTAssertEqual(simd_length(point), simd_length(converted), accuracy: 0.0001)
    }

    func testNormalConversionMatchesPositionConversion() {
        let normal = SIMD3<Float>(0, 1, 0)
        XCTAssertEqual(TopographicAxisConvention.convertNormal(normal), TopographicAxisConvention.convert(normal))
    }
}
