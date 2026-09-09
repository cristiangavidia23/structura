import Foundation
import simd

/// Frame-to-frame angular-velocity gate — Fase 2 of the architecture audit,
/// finding E1: `ProScanConfig.maximumAngularVelocityRadiansPerSecond` was
/// declared and unit-tested (`ProScanConfigTests
/// .testMaximumAngularVelocityIsPositive`) but no file actually consumed
/// it, so every frame was accumulated regardless of how fast the camera was
/// rotating.
///
/// This is a different question from what `FrameGate.isTrackingReliable`
/// already answers. `FrameGate` deliberately still accepts
/// `.limited(.excessiveMotion)` — see its own doc comment — because ARKit's
/// pose estimate during ordinary handheld panning is still real, just
/// lower-confidence, and rejecting it outright discarded most of a scan.
/// But "ARKit still trusts its own pose estimate" and "this frame's
/// depth/color samples are sharp enough to fuse in" are independent: a
/// frame captured mid-fast-rotation carries more motion blur in what it
/// actually sampled even when ARKit's tracking-confidence label doesn't
/// reflect that yet. This type answers the second question, and is meant
/// to run *alongside* `FrameGate`, not replace it.
///
/// Pure `simd` math operating only on `simd_float4x4`/`TimeInterval` — the
/// same types `ARCamera.transform`/`ARFrame.timestamp` already hand the
/// call site — so, like `ProScanConfig`/`ConfidenceGrid`/`CameraUnprojection`,
/// this has no ARKit dependency and compiles into the host-less
/// `StructuraTests` logic-test target, exercised with synthetic transforms
/// rather than a real device.
struct AngularVelocityGate {
    private var previousTransform: simd_float4x4?
    private var previousTimestamp: TimeInterval?

    /// `true` if the rotation between the last-observed frame and this one,
    /// divided by the elapsed time, stays at or under
    /// `ProScanConfig.maximumAngularVelocityRadiansPerSecond`.
    ///
    /// Always `true` for the very first frame observed (nothing to compare
    /// against yet) and `false` for a degenerate non-positive elapsed time
    /// (a stale or out-of-order timestamp) — rejected on suspicion of bad
    /// input rather than risking a divide-by-zero or a meaningless
    /// negative rate.
    ///
    /// Updates the stored previous transform/timestamp as a side effect
    /// **on every call, regardless of the verdict** — so this keeps
    /// comparing each newly observed frame against the one immediately
    /// before it. Only ever comparing against the last frame that *passed*
    /// would let a slow, sustained pan through indefinitely, one frame at a
    /// time, without ever re-basing the comparison window against how far
    /// the camera has actually moved since the last accepted sample.
    mutating func isMotionAcceptable(transform: simd_float4x4, timestamp: TimeInterval) -> Bool {
        defer {
            previousTransform = transform
            previousTimestamp = timestamp
        }
        guard let previousTransform, let previousTimestamp else { return true }
        let elapsed = timestamp - previousTimestamp
        guard elapsed > 0 else { return false }

        let velocity = Self.angularVelocityRadiansPerSecond(
            from: previousTransform, to: transform, elapsedSeconds: elapsed
        )
        return velocity <= ProScanConfig.maximumAngularVelocityRadiansPerSecond
    }

    mutating func reset() {
        previousTransform = nil
        previousTimestamp = nil
    }

    /// The angle (radians) of the rotation taking `from`'s orientation to
    /// `to`'s, divided by `elapsedSeconds`. `.infinity` for a non-positive
    /// `elapsedSeconds`, rather than dividing by zero — callers that care
    /// about that case (`isMotionAcceptable`) guard against it themselves;
    /// this is exposed separately because it's the part worth testing in
    /// isolation from the gate's stateful frame-to-frame bookkeeping.
    static func angularVelocityRadiansPerSecond(
        from: simd_float4x4, to: simd_float4x4, elapsedSeconds: TimeInterval
    ) -> Float {
        guard elapsedSeconds > 0 else { return .infinity }
        return rotationAngleRadians(from: from, to: to) / Float(elapsedSeconds)
    }

    /// The non-negative angle (0...π radians) of the rotation that takes
    /// `from`'s orientation to `to`'s. Translation is irrelevant to an
    /// angular measurement, so this only ever looks at each transform's
    /// upper-left 3x3 rotation block.
    ///
    /// Computed from the trace of the relative rotation matrix
    /// (`R = R_to · R_from⁻¹`, and for a pure rotation `R_from⁻¹ ==
    /// R_from.transpose`) rather than via quaternions: `angle =
    /// acos((trace(R) - 1) / 2)` is the standard closed-form relationship
    /// between a rotation matrix's trace and its rotation angle, and needs
    /// only matrix multiply/transpose — operations already used elsewhere
    /// in this pipeline (`CameraUnprojection`) — instead of introducing a
    /// second representation (quaternions) into the codebase for this one
    /// call site.
    static func rotationAngleRadians(from: simd_float4x4, to: simd_float4x4) -> Float {
        let fromRotation = rotation3x3(of: from)
        let toRotation = rotation3x3(of: to)
        // `fromRotation` is a pure rotation (ARKit's camera transform has no
        // scale component), so its inverse is its transpose — this avoids a
        // general 3x3 matrix inverse just to undo an orthonormal rotation.
        let relative = toRotation * fromRotation.transpose
        let trace = relative[0][0] + relative[1][1] + relative[2][2]
        // Clamped to `acos`'s domain: floating-point error alone can push
        // `(trace - 1) / 2` a hair outside `-1...1` for a near-identity or
        // near-180°  relative rotation, which would otherwise make `acos`
        // return NaN instead of the (correct, near 0 or near π) answer.
        let cosineOfAngle = min(1, max(-1, (trace - 1) / 2))
        return acos(cosineOfAngle)
    }

    private static func rotation3x3(of transform: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(transform[0][0], transform[0][1], transform[0][2]),
            SIMD3<Float>(transform[1][0], transform[1][1], transform[1][2]),
            SIMD3<Float>(transform[2][0], transform[2][1], transform[2][2])
        )
    }
}
