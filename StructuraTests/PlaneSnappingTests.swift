import simd
import XCTest

final class PlaneSnappingTests: XCTestCase {
    // MARK: - maxAngularSpread

    func testMaxAngularSpreadIsZeroForIdenticalNormals() throws {
        let normals = Array(repeating: SIMD3<Float>(0, 1, 0), count: 5)
        let spread = try XCTUnwrap(PlaneSnapping.maxAngularSpread(of: normals))
        XCTAssertEqual(spread, 0, accuracy: 0.0001)
    }

    func testMaxAngularSpreadMatchesAKnownAngle() throws {
        // Two normals 90° apart; the mean sits at 45° from each, so the
        // max spread from the mean is 45° (π/4).
        let normals: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0)]
        let spread = try XCTUnwrap(PlaneSnapping.maxAngularSpread(of: normals))
        XCTAssertEqual(spread, .pi / 4, accuracy: 0.001)
    }

    func testMaxAngularSpreadIsNilForEmptyInput() {
        XCTAssertNil(PlaneSnapping.maxAngularSpread(of: []))
    }

    // MARK: - fitPlane

    func testFitPlaneRecoversTheKnownPlaneFromAFlatNeighborhood() throws {
        // A horizontal plane at y = 2, normal (0,1,0).
        var points: [PointCloudExportPoint] = []
        for x in stride(from: Float(-0.1), through: 0.1, by: 0.02) {
            for z in stride(from: Float(-0.1), through: 0.1, by: 0.02) {
                points.append(PointCloudExportPoint(position: SIMD3(x, 2, z), confidence: 1.0, normal: SIMD3(0, 1, 0)))
            }
        }
        let plane = try XCTUnwrap(PlaneSnapping.fitPlane(
            around: SIMD3(0, 2, 0), in: points, radius: 0.2,
            minimumNeighbors: 6, maxAngularSpreadRadians: 0.3
        ))
        XCTAssertEqual(plane.normal, SIMD3<Float>(0, 1, 0), accuracy: 0.001)
        XCTAssertEqual(plane.point.y, 2, accuracy: 0.001)
    }

    func testFitPlaneReturnsNilBelowMinimumNeighborCount() {
        let points = [
            PointCloudExportPoint(position: SIMD3(0, 0, 0), confidence: 1.0, normal: SIMD3(0, 1, 0)),
            PointCloudExportPoint(position: SIMD3(0.01, 0, 0), confidence: 1.0, normal: SIMD3(0, 1, 0)),
        ]
        let plane = PlaneSnapping.fitPlane(
            around: SIMD3(0, 0, 0), in: points, radius: 0.2,
            minimumNeighbors: 6, maxAngularSpreadRadians: 0.3
        )
        XCTAssertNil(plane)
    }

    func testFitPlaneReturnsNilWhenNeighborhoodIsNotFlat() {
        // Half the neighbors face up, half face sideways — not one plane.
        var points: [PointCloudExportPoint] = []
        for i in 0..<10 {
            let normal: SIMD3<Float> = i % 2 == 0 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
            points.append(PointCloudExportPoint(position: SIMD3(Float(i) * 0.01, 0, 0), confidence: 1.0, normal: normal))
        }
        let plane = PlaneSnapping.fitPlane(
            around: SIMD3(0, 0, 0), in: points, radius: 0.2,
            minimumNeighbors: 6, maxAngularSpreadRadians: 0.3 // ~17°, far less than the 90° actually present
        )
        XCTAssertNil(plane, "A neighborhood mixing two very different surface orientations must not be fit as one plane.")
    }

    // MARK: - project

    func testProjectSnapsAPointExactlyOntoThePlane() {
        let plane = PlaneSnapping.Plane(point: SIMD3(0, 2, 0), normal: SIMD3(0, 1, 0))
        let above = SIMD3<Float>(1, 2.5, 3) // 0.5 m above the plane
        let projected = PlaneSnapping.project(above, onto: plane)

        XCTAssertEqual(projected, SIMD3<Float>(1, 2, 3), accuracy: 0.0001)
    }

    func testProjectingAPointAlreadyOnThePlaneIsAFixedPoint() {
        let plane = PlaneSnapping.Plane(point: SIMD3(0, 0, 0), normal: SIMD3(0, 0, 1))
        let onPlane = SIMD3<Float>(5, -3, 0)
        XCTAssertEqual(PlaneSnapping.project(onPlane, onto: plane), onPlane, accuracy: 0.0001)
    }
}

private func XCTAssertEqual(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>, accuracy: Float, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(lhs.x, rhs.x, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(lhs.y, rhs.y, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(lhs.z, rhs.z, accuracy: accuracy, file: file, line: line)
}
