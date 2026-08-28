import simd
import XCTest

final class PointCloudRaycastTests: XCTestCase {
    private func point(_ position: SIMD3<Float>, normal: SIMD3<Float> = SIMD3(0, 1, 0)) -> PointCloudExportPoint {
        PointCloudExportPoint(position: position, confidence: 1.0, normal: normal)
    }

    func testFindsAPointDirectlyOnTheRay() throws {
        let points = [point(SIMD3(0, 0, -5)), point(SIMD3(10, 10, 10))]
        let hit = try XCTUnwrap(PointCloudRaycast.nearestPoint(
            in: points, rayOrigin: .zero, rayDirection: SIMD3(0, 0, -1), maxPerpendicularDistance: 0.01
        ))
        XCTAssertEqual(hit.pointIndex, 0)
        XCTAssertEqual(hit.position, SIMD3(0, 0, -5))
    }

    func testMissesEverythingBeyondMaxPerpendicularDistance() {
        let points = [point(SIMD3(1.0, 0, -5))] // 1 m off the ray
        let hit = PointCloudRaycast.nearestPoint(
            in: points, rayOrigin: .zero, rayDirection: SIMD3(0, 0, -1), maxPerpendicularDistance: 0.05
        )
        XCTAssertNil(hit)
    }

    func testIgnoresPointsBehindTheRayOrigin() {
        let points = [point(SIMD3(0, 0, 5))] // behind, if the ray looks toward -Z
        let hit = PointCloudRaycast.nearestPoint(
            in: points, rayOrigin: .zero, rayDirection: SIMD3(0, 0, -1), maxPerpendicularDistance: 1.0
        )
        XCTAssertNil(hit)
    }

    func testPicksTheClosestOfMultipleCandidatesWithinTolerance() throws {
        let points = [
            point(SIMD3(0.04, 0, -5)), // 4 cm off the ray
            point(SIMD3(0.01, 0, -3)), // 1 cm off the ray, and closer along it
        ]
        let hit = try XCTUnwrap(PointCloudRaycast.nearestPoint(
            in: points, rayOrigin: .zero, rayDirection: SIMD3(0, 0, -1), maxPerpendicularDistance: 0.05
        ))
        XCTAssertEqual(hit.pointIndex, 1, "The point nearer to the ray line itself must win, not the one merely closer along the ray.")
    }

    func testReturnsNilForAZeroLengthDirection() {
        let points = [point(SIMD3(0, 0, -5))]
        XCTAssertNil(PointCloudRaycast.nearestPoint(in: points, rayOrigin: .zero, rayDirection: .zero, maxPerpendicularDistance: 1.0))
    }
}
