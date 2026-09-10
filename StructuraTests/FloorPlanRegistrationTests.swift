import XCTest
import simd

/// The core property under test is recoverability: take a known room, apply a
/// known rotation and translation to it, and check that registration returns
/// the transform that undoes it. That is checkable exactly, unlike "does the
/// overlay look right", which is the only other way to judge this.
final class FloorPlanRegistrationTests: XCTestCase {

    private typealias Segment2D = FloorPlanRegistration.Segment2D
    private typealias Transform = FloorPlanRegistration.Transform

    /// A closed rectangular room, walls running counter-clockwise.
    private func rectangularRoom(width: Float = 4, depth: Float = 3) -> [Segment2D] {
        let corners = [
            SIMD2<Float>(0, 0),
            SIMD2<Float>(width, 0),
            SIMD2<Float>(width, depth),
            SIMD2<Float>(0, depth)
        ]
        return (0..<4).map { index in
            Segment2D(start: corners[index], end: corners[(index + 1) % 4])
        }
    }

    /// Deliberately not rectilinear and not symmetric under any quarter turn,
    /// so tests that need an unambiguous orientation have one.
    private func asymmetricRoom() -> [Segment2D] {
        [
            Segment2D(start: SIMD2(0, 0), end: SIMD2(5, 0)),
            Segment2D(start: SIMD2(5, 0), end: SIMD2(5, 2)),
            Segment2D(start: SIMD2(5, 2), end: SIMD2(2.5, 3.4)),
            Segment2D(start: SIMD2(2.5, 3.4), end: SIMD2(0, 2)),
            Segment2D(start: SIMD2(0, 2), end: SIMD2(0, 0))
        ]
    }

    private func transformed(_ segments: [Segment2D], by transform: Transform) -> [Segment2D] {
        segments.map(transform.apply(to:))
    }

    // MARK: - Transform algebra

    func testTransformAppliesRotationThenTranslation() {
        let transform = Transform(rotationRadians: .pi / 2, translation: SIMD2(1, 2))
        let moved = transform.apply(to: SIMD2<Float>(1, 0))
        // (1,0) rotated 90° is (0,1); translation then puts it at (1,3).
        XCTAssertEqual(moved.x, 1, accuracy: 1e-5)
        XCTAssertEqual(moved.y, 3, accuracy: 1e-5)
    }

    // MARK: - Recovering a known transform

    func testRecoversAPureTranslation() throws {
        let room = asymmetricRoom()
        let applied = Transform(rotationRadians: 0, translation: SIMD2(1.5, -2.25))
        let result = try XCTUnwrap(FloorPlanRegistration.align(room, to: transformed(room, by: applied)))

        XCTAssertEqual(result.transform.translation.x, applied.translation.x, accuracy: 0.01)
        XCTAssertEqual(result.transform.translation.y, applied.translation.y, accuracy: 0.01)
        XCTAssertLessThan(result.medianResidualMeters, 0.01)
    }

    func testRecoversARotationAndTranslationTogether() throws {
        let room = asymmetricRoom()
        let applied = Transform(rotationRadians: 0.7, translation: SIMD2(-3, 4))
        let result = try XCTUnwrap(FloorPlanRegistration.align(room, to: transformed(room, by: applied)))

        // Compare the effect, not the parameters: rotations are only defined
        // modulo 2π, so equal transforms can carry unequal angle values.
        for corner in [SIMD2<Float>(0, 0), SIMD2<Float>(5, 0), SIMD2<Float>(2.5, 3.4)] {
            let expected = applied.apply(to: corner)
            let actual = result.transform.apply(to: corner)
            XCTAssertEqual(actual.x, expected.x, accuracy: 0.02)
            XCTAssertEqual(actual.y, expected.y, accuracy: 0.02)
        }
        XCTAssertLessThan(result.medianResidualMeters, 0.02)
        XCTAssertGreaterThan(result.inlierFraction, 0.95)
    }

    /// The quarter-turn search exists for exactly this: the seeded rotation
    /// from dominant orientations is ambiguous modulo 90°, so a room rotated
    /// by nearly a quarter turn is the case a single-seed fit gets wrong.
    func testRecoversARotationNearAQuarterTurn() throws {
        let room = asymmetricRoom()
        let applied = Transform(rotationRadians: .pi / 2 - 0.05, translation: SIMD2(2, 1))
        let result = try XCTUnwrap(FloorPlanRegistration.align(room, to: transformed(room, by: applied)))

        let corner = SIMD2<Float>(5, 2)
        let expected = applied.apply(to: corner)
        let actual = result.transform.apply(to: corner)
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.05)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.05)
    }

    func testAlignsARoomThatIsAlreadyInPlaceToTheIdentity() throws {
        let room = rectangularRoom()
        let result = try XCTUnwrap(FloorPlanRegistration.align(room, to: room))
        XCTAssertLessThan(result.medianResidualMeters, 0.01)
        for corner in [SIMD2<Float>(0, 0), SIMD2<Float>(4, 3)] {
            let actual = result.transform.apply(to: corner)
            XCTAssertEqual(actual.x, corner.x, accuracy: 0.02)
            XCTAssertEqual(actual.y, corner.y, accuracy: 0.02)
        }
    }

    // MARK: - Robustness

    func testToleratesNoiseOnTheSourceWalls() throws {
        let room = asymmetricRoom()
        let applied = Transform(rotationRadians: 0.35, translation: SIMD2(1, 1))
        var generator = SystemRandomNumberGenerator()
        let noisy = transformed(room, by: applied).map { segment -> Segment2D in
            func jitter() -> SIMD2<Float> {
                SIMD2(Float.random(in: -0.03...0.03, using: &generator),
                      Float.random(in: -0.03...0.03, using: &generator))
            }
            return Segment2D(start: segment.start + jitter(), end: segment.end + jitter())
        }

        let result = try XCTUnwrap(FloorPlanRegistration.align(room, to: noisy))
        // Recovering to well inside the noise amplitude, not to zero: the
        // target itself moved, so an exact fit doesn't exist.
        XCTAssertLessThan(result.medianResidualMeters, 0.05)
        XCTAssertGreaterThan(result.inlierFraction, 0.9)
    }

    /// Pro Scan and RoomPlan rarely cover exactly the same surfaces — one
    /// sees a wall the other missed. Those unmatched walls must not drag the
    /// fit, which is why the score is a median over inliers rather than a mean.
    func testExtraWallInTheSourceDoesNotWreckTheFit() throws {
        let room = asymmetricRoom()
        let applied = Transform(rotationRadians: 0.2, translation: SIMD2(0.5, -1))
        let target = transformed(room, by: applied)

        var sourceWithExtra = room
        sourceWithExtra.append(Segment2D(start: SIMD2(-6, -6), end: SIMD2(-6, -3)))

        let result = try XCTUnwrap(FloorPlanRegistration.align(sourceWithExtra, to: target))
        let corner = SIMD2<Float>(5, 0)
        let expected = applied.apply(to: corner)
        let actual = result.transform.apply(to: corner)
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.15)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.15)
    }

    func testReportsALowInlierFractionForPlansThatDoNotMatch() throws {
        // A long corridor and a small square describe different places; the
        // fit must say so rather than return a confident-looking transform.
        let corridor = [
            Segment2D(start: SIMD2(0, 0), end: SIMD2(20, 0)),
            Segment2D(start: SIMD2(0, 1.2), end: SIMD2(20, 1.2))
        ]
        let square = rectangularRoom(width: 2, depth: 2)
        let result = try XCTUnwrap(FloorPlanRegistration.align(corridor, to: square))
        XCTAssertLessThan(result.inlierFraction, 0.6)
    }

    // MARK: - Degenerate input

    func testReturnsNilWhenEitherSideHasNoUsableGeometry() {
        let room = rectangularRoom()
        XCTAssertNil(FloorPlanRegistration.align([], to: room))
        XCTAssertNil(FloorPlanRegistration.align(room, to: []))
        // Zero-length segments carry no geometry and are filtered out, which
        // leaves nothing to fit.
        let degenerate = [Segment2D(start: SIMD2(1, 1), end: SIMD2(1, 1))]
        XCTAssertNil(FloorPlanRegistration.align(degenerate, to: room))
    }

    // MARK: - Building blocks

    func testDominantOrientationTreatsPerpendicularWallsAsOneGrid() {
        let axisAligned = rectangularRoom()
        XCTAssertEqual(FloorPlanRegistration.dominantOrientation(of: axisAligned), 0, accuracy: 0.01)

        let rotation: Float = 0.3
        let rotated = transformed(axisAligned, by: Transform(rotationRadians: rotation, translation: .zero))
        XCTAssertEqual(FloorPlanRegistration.dominantOrientation(of: rotated), rotation, accuracy: 0.01)
    }

    func testClosestPointClampsToTheSegmentRatherThanItsInfiniteLine() {
        let segment = Segment2D(start: SIMD2(0, 0), end: SIMD2(2, 0))
        let beyondEnd = FloorPlanRegistration.closestPoint(to: SIMD2(9, 1), on: segment)
        XCTAssertEqual(beyondEnd.x, 2, accuracy: 1e-5)
        XCTAssertEqual(beyondEnd.y, 0, accuracy: 1e-5)

        let alongside = FloorPlanRegistration.closestPoint(to: SIMD2(1, 5), on: segment)
        XCTAssertEqual(alongside.x, 1, accuracy: 1e-5)
    }

    func testRigidTransformNeedsAtLeastTwoCorrespondences() {
        XCTAssertNil(FloorPlanRegistration.rigidTransform(from: [SIMD2(0, 0)], to: [SIMD2(1, 1)]))
        XCTAssertNil(FloorPlanRegistration.rigidTransform(from: [SIMD2(0, 0)], to: [SIMD2(1, 1), SIMD2(2, 2)]))
    }

    func testSampledPointsStayWithinTheSampleCeiling() {
        // A wall far longer than spacing x ceiling would exceed the cap if the
        // spacing weren't widened to compensate.
        let huge = [Segment2D(start: SIMD2(0, 0), end: SIMD2(10_000, 0))]
        let samples = FloorPlanRegistration.sampledPoints(along: huge)
        XCTAssertLessThanOrEqual(samples.count, FloorPlanRegistration.maximumSamples + 2)
    }
}
