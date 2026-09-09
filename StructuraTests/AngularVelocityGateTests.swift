import simd
import XCTest

/// Synthetic-transform acceptance tests for `AngularVelocityGate` — Fase 2
/// of the architecture audit, finding E1. `ProScanConfig
/// .maximumAngularVelocityRadiansPerSecond` already had a trivial existence
/// test (`ProScanConfigTests.testMaximumAngularVelocityIsPositive`); these
/// exercise the actual gating math it was declared for, which nothing
/// previously consumed.
final class AngularVelocityGateTests: XCTestCase {

    // MARK: - rotationAngleRadians

    func testRotationAngleIsZeroForIdenticalTransforms() {
        let transform = makeTransform(rotationAroundYRadians: 0.4)
        let angle = AngularVelocityGate.rotationAngleRadians(from: transform, to: transform)
        XCTAssertEqual(angle, 0, accuracy: 0.001)
    }

    func testRotationAngleMatchesTheDifferenceBetweenTwoAnglesAboutTheSameAxis() {
        let from = makeTransform(rotationAroundYRadians: 0.2)
        let to = makeTransform(rotationAroundYRadians: 0.7)
        let angle = AngularVelocityGate.rotationAngleRadians(from: from, to: to)
        XCTAssertEqual(angle, 0.5, accuracy: 0.001)
    }

    func testRotationAngleIsDirectionAgnostic() {
        // Rotating +0.3 rad or -0.3 rad from the identity is the same
        // *magnitude* of motion — this measures speed, not heading.
        let identity = makeTransform(rotationAroundYRadians: 0)
        let positive = makeTransform(rotationAroundYRadians: 0.3)
        let negative = makeTransform(rotationAroundYRadians: -0.3)
        XCTAssertEqual(
            AngularVelocityGate.rotationAngleRadians(from: identity, to: positive),
            AngularVelocityGate.rotationAngleRadians(from: identity, to: negative),
            accuracy: 0.001
        )
    }

    func testRotationAngleIgnoresTranslation() {
        let from = makeTransform(rotationAroundYRadians: 0.1, translation: SIMD3<Float>(0, 0, 0))
        let to = makeTransform(rotationAroundYRadians: 0.1, translation: SIMD3<Float>(5, 2, -3))
        let angle = AngularVelocityGate.rotationAngleRadians(from: from, to: to)
        XCTAssertEqual(angle, 0, accuracy: 0.001)
    }

    func testRotationAngleAboutDifferentAxesIsNotSimplyAdditive() {
        // Sanity check that the trace-based formula degrades gracefully
        // (stays within the valid 0...π range, doesn't NaN) for rotations
        // about different axes, not just the same-axis case the other
        // tests use for an exact expected value.
        let from = makeTransform(rotationAroundYRadians: 0.2)
        let to = makeTransform(rotationAroundZRadians: 0.4)
        let angle = AngularVelocityGate.rotationAngleRadians(from: from, to: to)
        XCTAssertFalse(angle.isNaN)
        XCTAssertGreaterThanOrEqual(angle, 0)
        XCTAssertLessThanOrEqual(angle, Float.pi)
    }

    // MARK: - angularVelocityRadiansPerSecond

    func testAngularVelocityDividesAngleByElapsedTime() {
        let from = makeTransform(rotationAroundYRadians: 0)
        let to = makeTransform(rotationAroundYRadians: 1.0)
        let velocity = AngularVelocityGate.angularVelocityRadiansPerSecond(from: from, to: to, elapsedSeconds: 0.5)
        XCTAssertEqual(velocity, 2.0, accuracy: 0.001)
    }

    func testAngularVelocityIsInfiniteForNonPositiveElapsedTime() {
        let from = makeTransform(rotationAroundYRadians: 0)
        let to = makeTransform(rotationAroundYRadians: 1.0)
        XCTAssertEqual(AngularVelocityGate.angularVelocityRadiansPerSecond(from: from, to: to, elapsedSeconds: 0), .infinity)
        XCTAssertEqual(AngularVelocityGate.angularVelocityRadiansPerSecond(from: from, to: to, elapsedSeconds: -0.1), .infinity)
    }

    // MARK: - isMotionAcceptable (stateful gate)

    func testFirstObservedFrameIsAlwaysAcceptable() {
        var gate = AngularVelocityGate()
        // An extreme rotation, but there is nothing to compare it against yet.
        let transform = makeTransform(rotationAroundYRadians: 3.0)
        XCTAssertTrue(gate.isMotionAcceptable(transform: transform, timestamp: 10.0))
    }

    func testSlowRotationIsAccepted() {
        var gate = AngularVelocityGate()
        _ = gate.isMotionAcceptable(transform: makeTransform(rotationAroundYRadians: 0), timestamp: 0)
        // 0.1 rad over 0.5 s = 0.2 rad/s, well under the 1.0 rad/s default.
        let accepted = gate.isMotionAcceptable(transform: makeTransform(rotationAroundYRadians: 0.1), timestamp: 0.5)
        XCTAssertTrue(accepted)
    }

    func testFastRotationIsRejected() {
        var gate = AngularVelocityGate()
        _ = gate.isMotionAcceptable(transform: makeTransform(rotationAroundYRadians: 0), timestamp: 0)
        // 1.5 rad over 0.5 s = 3.0 rad/s, well over the 1.0 rad/s default.
        let accepted = gate.isMotionAcceptable(transform: makeTransform(rotationAroundYRadians: 1.5), timestamp: 0.5)
        XCTAssertFalse(accepted)
    }

    func testNonPositiveElapsedTimeIsRejectedRatherThanCrashing() {
        var gate = AngularVelocityGate()
        _ = gate.isMotionAcceptable(transform: makeTransform(rotationAroundYRadians: 0), timestamp: 5.0)
        // A stale/out-of-order timestamp, not later than the previous one.
        let accepted = gate.isMotionAcceptable(transform: makeTransform(rotationAroundYRadians: 0.05), timestamp: 5.0)
        XCTAssertFalse(accepted)
    }

    func testGateAlwaysComparesAgainstTheImmediatelyPrecedingFrameNotTheLastAcceptedOne() {
        var gate = AngularVelocityGate()
        _ = gate.isMotionAcceptable(transform: makeTransform(rotationAroundYRadians: 0), timestamp: 0)
        // Rejected: 1.5 rad / 0.5 s = 3.0 rad/s.
        XCTAssertFalse(gate.isMotionAcceptable(transform: makeTransform(rotationAroundYRadians: 1.5), timestamp: 0.5))
        // The next comparison must be against the *rejected* frame at t=0.5
        // (angle 1.5), not the last *accepted* one at t=0 (angle 0) — a
        // small move from here should be accepted even though it would have
        // been a huge, rejected jump from the original t=0 baseline.
        let accepted = gate.isMotionAcceptable(transform: makeTransform(rotationAroundYRadians: 1.55), timestamp: 1.0)
        XCTAssertTrue(accepted)
    }

    func testResetForgetsThePreviousFrame() {
        var gate = AngularVelocityGate()
        _ = gate.isMotionAcceptable(transform: makeTransform(rotationAroundYRadians: 0), timestamp: 0)
        gate.reset()
        // Without a previous frame to compare against, even a transform
        // that would otherwise read as an enormous jump is accepted.
        let accepted = gate.isMotionAcceptable(transform: makeTransform(rotationAroundYRadians: 3.0), timestamp: 0.01)
        XCTAssertTrue(accepted)
    }

    // MARK: - Synthetic transforms

    private func makeTransform(rotationAroundYRadians angle: Float, translation: SIMD3<Float> = .zero) -> simd_float4x4 {
        let c = cos(angle)
        let s = sin(angle)
        let col0 = SIMD4<Float>(c, 0, -s, 0)
        let col1 = SIMD4<Float>(0, 1, 0, 0)
        let col2 = SIMD4<Float>(s, 0, c, 0)
        let col3 = SIMD4<Float>(translation.x, translation.y, translation.z, 1)
        return simd_float4x4(col0, col1, col2, col3)
    }

    private func makeTransform(rotationAroundZRadians angle: Float, translation: SIMD3<Float> = .zero) -> simd_float4x4 {
        let c = cos(angle)
        let s = sin(angle)
        let col0 = SIMD4<Float>(c, s, 0, 0)
        let col1 = SIMD4<Float>(-s, c, 0, 0)
        let col2 = SIMD4<Float>(0, 0, 1, 0)
        let col3 = SIMD4<Float>(translation.x, translation.y, translation.z, 1)
        return simd_float4x4(col0, col1, col2, col3)
    }
}
