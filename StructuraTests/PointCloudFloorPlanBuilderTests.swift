import simd
import XCTest

/// Synthetic-data tests for `PointCloudFloorPlanBuilder` — Fase 4 of the
/// architecture audit. There is no real LiDAR recording available in this
/// environment, so every test constructs an idealized point cloud (a
/// rectangular room's floor + walls, optionally with injected noise or
/// furniture-like confounders) and checks that the pipeline recovers the
/// geometry that generated it. That is deliberately a weaker claim than
/// "validated against a real scan" — see the type's own doc comment.
final class PointCloudFloorPlanBuilderTests: XCTestCase {

    typealias Builder = PointCloudFloorPlanBuilder

    // MARK: - estimateFloorHeight

    func testFloorHeightIsNilForEmptyInput() {
        XCTAssertNil(Builder.estimateFloorHeight(positions: [], normals: []))
    }

    func testFloorHeightIsNilWhenNoNormalIsNearVertical() {
        // Every normal points sideways (wall-like) — nothing looks like a
        // floor or ceiling.
        let positions = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1)]
        let normals = [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, 1)]
        XCTAssertNil(Builder.estimateFloorHeight(positions: positions, normals: normals))
    }

    func testFloorHeightPicksLargestLowClusterOverSingleStrayPoint() {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []

        // A single stray low-noise sample at y = -0.5 (e.g. a bad depth
        // reading) should not be mistaken for the floor.
        positions.append(SIMD3<Float>(0, -0.5, 0))
        normals.append(SIMD3<Float>(0, 1, 0))

        // The real floor: a broad cluster of horizontal points at y ≈ 0.
        for i in 0..<50 {
            let jitter = Float(i % 5) * 0.001
            positions.append(SIMD3<Float>(Float(i) * 0.1, jitter, 0))
            normals.append(SIMD3<Float>(0, 1, 0))
        }

        // A ceiling cluster at y ≈ 2.4 — larger total height but not in the
        // lower half of the observed range, so it shouldn't win either.
        for i in 0..<80 {
            positions.append(SIMD3<Float>(Float(i) * 0.1, 2.4, 0))
            normals.append(SIMD3<Float>(0, -1, 0))
        }

        guard let floorHeight = Builder.estimateFloorHeight(positions: positions, normals: normals) else {
            return XCTFail("Expected a floor height estimate.")
        }
        XCTAssertEqual(floorHeight, 0, accuracy: 0.05)
    }

    func testFloorHeightIgnoresNearVerticalWallNormals() {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []

        for i in 0..<30 {
            positions.append(SIMD3<Float>(Float(i) * 0.1, 0, 0))
            normals.append(SIMD3<Float>(0, 1, 0))
        }
        // Wall-like points scattered across a wide height range that would
        // badly skew a naive "just average the height" approach if included.
        for i in 0..<200 {
            positions.append(SIMD3<Float>(0, Float(i) * 0.05, 0))
            normals.append(SIMD3<Float>(1, 0, 0))
        }

        guard let floorHeight = Builder.estimateFloorHeight(positions: positions, normals: normals) else {
            return XCTFail("Expected a floor height estimate.")
        }
        XCTAssertEqual(floorHeight, 0, accuracy: 0.05)
    }

    func testFloorHeightWithDegenerateSingleHeightReturnsThatHeight() {
        let positions = [SIMD3<Float>(0, 1.2, 0), SIMD3<Float>(1, 1.2, 1)]
        let normals = [SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 1, 0)]
        XCTAssertEqual(Builder.estimateFloorHeight(positions: positions, normals: normals), 1.2)
    }

    // MARK: - wallCandidatePoints2D

    func testWallCandidateSliceKeepsOnlyPointsInBandWithSidewaysNormal() {
        let floorHeight: Float = 0
        let positions: [SIMD3<Float>] = [
            SIMD3<Float>(1, 1.0, 2),   // in band, wall-like normal -> kept
            SIMD3<Float>(3, 1.0, 4),   // in band, floor-like normal -> dropped
            SIMD3<Float>(5, 2.0, 6),   // out of band -> dropped
            SIMD3<Float>(7, 0.95, 8), // just inside band edge, wall-like -> kept
        ]
        let normals: [SIMD3<Float>] = [
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 0, 1),
        ]
        let result = Builder.wallCandidatePoints2D(
            positions: positions, normals: normals, floorHeight: floorHeight,
            sliceHeightAboveFloor: 1.0, sliceThickness: 0.15
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.contains(SIMD2<Float>(1, 2)))
        XCTAssertTrue(result.contains(SIMD2<Float>(7, 8)))
    }

    func testWallCandidateSliceHandlesZeroLengthNormalGracefully() {
        let positions: [SIMD3<Float>] = [SIMD3<Float>(0, 1.0, 0)]
        let normals: [SIMD3<Float>] = [SIMD3<Float>.zero]
        let result = Builder.wallCandidatePoints2D(positions: positions, normals: normals, floorHeight: 0)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - RANSAC line detection

    private func syntheticWallPoints(
        from start: SIMD2<Float>, to end: SIMD2<Float>, count: Int, noise: Float = 0
    ) -> [SIMD2<Float>] {
        var generator = Builder.SeededGenerator(seed: 42)
        var points: [SIMD2<Float>] = []
        for i in 0..<count {
            let t = Float(i) / Float(max(count - 1, 1))
            var point = start + (end - start) * t
            if noise > 0 {
                let dx = Float.random(in: -noise...noise, using: &generator)
                let dy = Float.random(in: -noise...noise, using: &generator)
                point += SIMD2<Float>(dx, dy)
            }
            points.append(point)
        }
        return points
    }

    func testDetectWallLinesFindsASingleCleanLine() {
        let points = syntheticWallPoints(from: SIMD2<Float>(0, 0), to: SIMD2<Float>(4, 0), count: 60)
        var generator = Builder.SeededGenerator(seed: 1)
        let lines = Builder.detectWallLines(points: points, minimumInliers: 20, generator: &generator)
        XCTAssertEqual(lines.count, 1)
        guard let line = lines.first else { return }
        XCTAssertEqual(line.inlierCount, 60)
        XCTAssertEqual(abs(line.end.x - line.start.x), 4, accuracy: 0.05)
        XCTAssertEqual(line.start.y, 0, accuracy: 0.02)
        XCTAssertEqual(line.end.y, 0, accuracy: 0.02)
    }

    func testDetectWallLinesFindsFourWallsOfARectangle() {
        var points: [SIMD2<Float>] = []
        points += syntheticWallPoints(from: SIMD2<Float>(0, 0), to: SIMD2<Float>(4, 0), count: 40)
        points += syntheticWallPoints(from: SIMD2<Float>(4, 0), to: SIMD2<Float>(4, 3), count: 30)
        points += syntheticWallPoints(from: SIMD2<Float>(4, 3), to: SIMD2<Float>(0, 3), count: 40)
        points += syntheticWallPoints(from: SIMD2<Float>(0, 3), to: SIMD2<Float>(0, 0), count: 30)

        var generator = Builder.SeededGenerator(seed: 7)
        let lines = Builder.detectWallLines(points: points, minimumInliers: 20, generator: &generator)
        XCTAssertEqual(lines.count, 4)
        for line in lines {
            XCTAssertGreaterThanOrEqual(line.inlierCount, 20)
        }
    }

    func testDetectWallLinesDiscardsWeaklySupportedLine() {
        // Fewer points than `minimumInliers` — should never be reported as
        // a detected wall.
        let points = syntheticWallPoints(from: SIMD2<Float>(0, 0), to: SIMD2<Float>(1, 0), count: 5)
        var generator = Builder.SeededGenerator(seed: 3)
        let lines = Builder.detectWallLines(points: points, minimumInliers: 20, generator: &generator)
        XCTAssertTrue(lines.isEmpty)
    }

    func testDetectWallLinesIsDeterministicForAFixedSeed() {
        let points = syntheticWallPoints(from: SIMD2<Float>(0, 0), to: SIMD2<Float>(2, 0), count: 40, noise: 0.01)
        var generatorA = Builder.SeededGenerator(seed: 99)
        var generatorB = Builder.SeededGenerator(seed: 99)
        let linesA = Builder.detectWallLines(points: points, minimumInliers: 10, generator: &generatorA)
        let linesB = Builder.detectWallLines(points: points, minimumInliers: 10, generator: &generatorB)
        XCTAssertEqual(linesA.count, linesB.count)
        for (a, b) in zip(linesA, linesB) {
            XCTAssertEqual(a.start, b.start)
            XCTAssertEqual(a.end, b.end)
            XCTAssertEqual(a.inlierCount, b.inlierCount)
        }
    }

    func testDetectWallLinesHandlesNearVerticalLine() {
        // A near-vertical wall would break a naive "y = mx + b" least
        // squares fit; the TLS refit must handle it via its covariance-angle
        // formula instead.
        let points = syntheticWallPoints(from: SIMD2<Float>(2, 0), to: SIMD2<Float>(2, 5), count: 50)
        var generator = Builder.SeededGenerator(seed: 11)
        let lines = Builder.detectWallLines(points: points, minimumInliers: 20, generator: &generator)
        XCTAssertEqual(lines.count, 1)
        guard let line = lines.first else { return }
        XCTAssertEqual(line.start.x, 2, accuracy: 0.05)
        XCTAssertEqual(line.end.x, 2, accuracy: 0.05)
        XCTAssertEqual(abs(line.end.y - line.start.y), 5, accuracy: 0.1)
    }

    func testDetectWallLinesOnEmptyInputReturnsEmpty() {
        var generator = Builder.SeededGenerator(seed: 5)
        let lines = Builder.detectWallLines(points: [], minimumInliers: 20, generator: &generator)
        XCTAssertTrue(lines.isEmpty)
    }

    // MARK: - dominantGridAngle

    func testDominantGridAngleOfAxisAlignedSegmentsIsZero() {
        let segments = [
            Builder.WallSegment(start: SIMD2<Float>(0, 0), end: SIMD2<Float>(4, 0), inlierCount: 40),
            Builder.WallSegment(start: SIMD2<Float>(4, 0), end: SIMD2<Float>(4, 3), inlierCount: 30),
        ]
        let angle = Builder.dominantGridAngle(of: segments)
        XCTAssertEqual(angle, 0, accuracy: 0.01)
    }

    func testDominantGridAngleFollowsARotatedRoom() {
        let rotation: Float = 10 * .pi / 180
        let cosA = cos(rotation), sinA = sin(rotation)
        let segments = [
            Builder.WallSegment(start: SIMD2<Float>(0, 0), end: SIMD2<Float>(4 * cosA, 4 * sinA), inlierCount: 40),
        ]
        let angle = Builder.dominantGridAngle(of: segments)
        XCTAssertEqual(angle, rotation, accuracy: 0.01)
    }

    func testDominantGridAngleOfEmptySegmentsIsZero() {
        XCTAssertEqual(Builder.dominantGridAngle(of: []), 0)
    }

    // MARK: - snapToGrid

    func testSnapToGridCorrectsASlightlyOffAngleSegment() {
        // Snapping rotates the segment about its own midpoint, it does not
        // translate it back onto the y = 0 line — so the correct check is
        // that the result is now perfectly horizontal (both endpoints share
        // a y), not that it landed at any particular y.
        let offsetRadians: Float = 2 * .pi / 180
        var segments = [
            Builder.WallSegment(start: SIMD2<Float>(0, 0), end: SIMD2<Float>(4 * cos(offsetRadians), 4 * sin(offsetRadians)), inlierCount: 40),
        ]
        Builder.snapToGrid(&segments, grid: 0, toleranceRadians: 5 * .pi / 180)
        XCTAssertFalse(segments[0].isOutOfSquare)
        XCTAssertEqual(segments[0].start.y, segments[0].end.y, accuracy: 0.001)
        XCTAssertEqual(segments[0].lengthMeters, 4, accuracy: 0.01)
    }

    func testSnapToGridFlagsOutOfSquareBeyondTolerance() {
        let offsetRadians: Float = 20 * .pi / 180
        var segments = [
            Builder.WallSegment(start: SIMD2<Float>(0, 0), end: SIMD2<Float>(4 * cos(offsetRadians), 4 * sin(offsetRadians)), inlierCount: 40),
        ]
        let originalEnd = segments[0].end
        Builder.snapToGrid(&segments, grid: 0, toleranceRadians: 5 * .pi / 180)
        XCTAssertTrue(segments[0].isOutOfSquare)
        XCTAssertEqual(segments[0].end, originalEnd)
    }

    func testSnapToGridSnapsToNearestOfFourCardinalDirections() {
        // Close to 90° (vertical), not 0° — same "check the resulting shape,
        // not an assumed absolute position" reasoning as the test above:
        // snapping to vertical means both endpoints now share an x.
        let angle: Float = 91 * .pi / 180
        var segments = [
            Builder.WallSegment(start: SIMD2<Float>(0, 0), end: SIMD2<Float>(3 * cos(angle), 3 * sin(angle)), inlierCount: 20),
        ]
        Builder.snapToGrid(&segments, grid: 0, toleranceRadians: 5 * .pi / 180)
        XCTAssertFalse(segments[0].isOutOfSquare)
        XCTAssertEqual(segments[0].start.x, segments[0].end.x, accuracy: 0.001)
        XCTAssertEqual(segments[0].lengthMeters, 3, accuracy: 0.01)
    }

    // MARK: - weldCorners

    func testWeldCornersJoinsTwoNearbyEndpoints() {
        var segments = [
            Builder.WallSegment(start: SIMD2<Float>(0, 0), end: SIMD2<Float>(4, 0.05), inlierCount: 40),
            Builder.WallSegment(start: SIMD2<Float>(4.05, 0), end: SIMD2<Float>(4, 3), inlierCount: 30),
        ]
        Builder.weldCorners(&segments, thresholdMeters: 0.6)
        XCTAssertEqual(segments[0].end, segments[1].start)
    }

    func testWeldCornersLeavesFarApartEndpointsUntouched() {
        var segments = [
            Builder.WallSegment(start: SIMD2<Float>(0, 0), end: SIMD2<Float>(4, 0), inlierCount: 40),
            Builder.WallSegment(start: SIMD2<Float>(10, 10), end: SIMD2<Float>(10, 13), inlierCount: 30),
        ]
        let originalEnd = segments[0].end
        let originalStart = segments[1].start
        Builder.weldCorners(&segments, thresholdMeters: 0.6)
        XCTAssertEqual(segments[0].end, originalEnd)
        XCTAssertEqual(segments[1].start, originalStart)
    }

    func testWeldCornersNoOpForSingleSegment() {
        var segments = [Builder.WallSegment(start: SIMD2<Float>(0, 0), end: SIMD2<Float>(4, 0), inlierCount: 40)]
        Builder.weldCorners(&segments, thresholdMeters: 0.6)
        XCTAssertEqual(segments[0].start, SIMD2<Float>(0, 0))
        XCTAssertEqual(segments[0].end, SIMD2<Float>(4, 0))
    }

    // MARK: - closePolygons

    func testClosePolygonsChainsFourSegmentsIntoOneRectangle() {
        let segments = [
            Builder.WallSegment(start: SIMD2<Float>(0, 0), end: SIMD2<Float>(4, 0), inlierCount: 40),
            Builder.WallSegment(start: SIMD2<Float>(4, 0), end: SIMD2<Float>(4, 3), inlierCount: 30),
            Builder.WallSegment(start: SIMD2<Float>(4, 3), end: SIMD2<Float>(0, 3), inlierCount: 40),
            Builder.WallSegment(start: SIMD2<Float>(0, 3), end: SIMD2<Float>(0, 0), inlierCount: 30),
        ]
        let polygons = Builder.closePolygons(from: segments)
        XCTAssertEqual(polygons.count, 1)
        XCTAssertEqual(polygons.first?.count, 5) // 4 corners + closing point back at start
    }

    func testClosePolygonsReturnsSeparatePolygonsForDisjointRooms() {
        let roomA = [
            Builder.WallSegment(start: SIMD2<Float>(0, 0), end: SIMD2<Float>(2, 0), inlierCount: 20),
            Builder.WallSegment(start: SIMD2<Float>(2, 0), end: SIMD2<Float>(2, 2), inlierCount: 20),
            Builder.WallSegment(start: SIMD2<Float>(2, 2), end: SIMD2<Float>(0, 2), inlierCount: 20),
            Builder.WallSegment(start: SIMD2<Float>(0, 2), end: SIMD2<Float>(0, 0), inlierCount: 20),
        ]
        let roomB = [
            Builder.WallSegment(start: SIMD2<Float>(20, 20), end: SIMD2<Float>(22, 20), inlierCount: 20),
            Builder.WallSegment(start: SIMD2<Float>(22, 20), end: SIMD2<Float>(22, 22), inlierCount: 20),
            Builder.WallSegment(start: SIMD2<Float>(22, 22), end: SIMD2<Float>(20, 22), inlierCount: 20),
            Builder.WallSegment(start: SIMD2<Float>(20, 22), end: SIMD2<Float>(20, 20), inlierCount: 20),
        ]
        let polygons = Builder.closePolygons(from: roomA + roomB)
        XCTAssertEqual(polygons.count, 2)
    }

    func testClosePolygonsDropsAnUnclosedChain() {
        // Two segments that never meet a third to close a loop -> not
        // reported as a polygon (fewer than 3 unique vertices).
        let segments = [
            Builder.WallSegment(start: SIMD2<Float>(0, 0), end: SIMD2<Float>(4, 0), inlierCount: 20),
        ]
        let polygons = Builder.closePolygons(from: segments)
        XCTAssertTrue(polygons.isEmpty)
    }

    // MARK: - build(from:) end-to-end

    /// Builds a synthetic rectangular-room point cloud: a horizontal floor
    /// slab, a horizontal ceiling slab, and four vertical wall slabs, dense
    /// enough at the wall-candidate slice height to support RANSAC.
    private func syntheticRoomPoints(width: Float = 4, depth: Float = 3, floorHeight: Float = 0, ceilingHeight: Float = 2.4) -> [PointCloudExportPoint] {
        var points: [PointCloudExportPoint] = []

        func addFloorOrCeiling(y: Float, normal: SIMD3<Float>) {
            var x: Float = 0
            while x <= width {
                var z: Float = 0
                while z <= depth {
                    points.append(PointCloudExportPoint(position: SIMD3<Float>(x, y, z), confidence: 1, normal: normal))
                    z += 0.2
                }
                x += 0.2
            }
        }
        addFloorOrCeiling(y: floorHeight, normal: SIMD3<Float>(0, 1, 0))
        addFloorOrCeiling(y: ceilingHeight, normal: SIMD3<Float>(0, -1, 0))

        func addWall(from start: SIMD2<Float>, to end: SIMD2<Float>, normal: SIMD3<Float>) {
            let steps = 60
            for i in 0...steps {
                let t = Float(i) / Float(steps)
                let point2D = start + (end - start) * t
                var y = floorHeight
                while y <= ceilingHeight {
                    points.append(PointCloudExportPoint(position: SIMD3<Float>(point2D.x, y, point2D.y), confidence: 1, normal: normal))
                    y += 0.2
                }
            }
        }
        addWall(from: SIMD2<Float>(0, 0), to: SIMD2<Float>(width, 0), normal: SIMD3<Float>(0, 0, -1))
        addWall(from: SIMD2<Float>(width, 0), to: SIMD2<Float>(width, depth), normal: SIMD3<Float>(1, 0, 0))
        addWall(from: SIMD2<Float>(width, depth), to: SIMD2<Float>(0, depth), normal: SIMD3<Float>(0, 0, 1))
        addWall(from: SIMD2<Float>(0, depth), to: SIMD2<Float>(0, 0), normal: SIMD3<Float>(-1, 0, 0))

        return points
    }

    func testBuildRecoversARectangularRoomEndToEnd() {
        let points = syntheticRoomPoints()
        guard let result = Builder.build(from: points) else {
            return XCTFail("Expected a non-nil result for a well-formed synthetic room.")
        }
        XCTAssertEqual(result.floorHeightMeters, 0, accuracy: 0.05)
        XCTAssertEqual(result.wallSegments.count, 4)
        XCTAssertEqual(result.polygons.count, 1)
        for segment in result.wallSegments {
            XCTAssertFalse(segment.isOutOfSquare)
        }

        // The recovered polygon's area should be close to the synthetic
        // room's 4 x 3 footprint (shoelace formula).
        guard let polygon = result.polygons.first else { return XCTFail("Expected one polygon.") }
        var area: Float = 0
        for i in 0..<polygon.count - 1 {
            let a = polygon[i], b = polygon[i + 1]
            area += a.x * b.y - b.x * a.y
        }
        area = abs(area) / 2
        XCTAssertEqual(area, 12, accuracy: 1.5)
    }

    func testBuildReturnsNilForACloudWithNoHorizontalSurface() {
        let points = [
            PointCloudExportPoint(position: SIMD3<Float>(0, 1, 0), confidence: 1, normal: SIMD3<Float>(1, 0, 0)),
            PointCloudExportPoint(position: SIMD3<Float>(1, 1, 1), confidence: 1, normal: SIMD3<Float>(0, 0, 1)),
        ]
        XCTAssertNil(Builder.build(from: points))
    }

    func testBuildReturnsEmptyWallsRatherThanNilWhenNoWallEvidenceExists() {
        // A floor and ceiling but no wall-like points at all: the floor
        // height should still resolve, but no walls/polygons should appear.
        var points: [PointCloudExportPoint] = []
        var x: Float = 0
        while x <= 2 {
            points.append(PointCloudExportPoint(position: SIMD3<Float>(x, 0, 0), confidence: 1, normal: SIMD3<Float>(0, 1, 0)))
            x += 0.1
        }
        guard let result = Builder.build(from: points) else {
            return XCTFail("Expected a non-nil result once floor height resolves.")
        }
        XCTAssertEqual(result.floorHeightMeters, 0, accuracy: 0.05)
        XCTAssertTrue(result.wallSegments.isEmpty)
        XCTAssertTrue(result.polygons.isEmpty)
    }
}
