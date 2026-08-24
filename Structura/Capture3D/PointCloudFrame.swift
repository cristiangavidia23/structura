import Foundation
import simd

/// One processed snapshot of dense scene points: unprojected positions plus
/// a matching per-point confidence value in [0, 1]. Built off the main
/// thread from `ARFrame.sceneDepth`; never retains the source `ARFrame`.
struct PointCloudFrame: Sendable {
    var positions: [SIMD3<Float>]
    var confidences: [Float]
    var timestamp: TimeInterval

    /// The exact view/projection ARKit used for this frame's camera. The
    /// Metal renderer draws with these rather than a synthetic orbit camera,
    /// so the points it just captured are guaranteed to sit inside the
    /// frustum instead of occasionally landing off-screen.
    var viewMatrix: simd_float4x4
    var projectionMatrix: simd_float4x4

    static let empty = PointCloudFrame(
        positions: [], confidences: [], timestamp: 0,
        viewMatrix: matrix_identity_float4x4, projectionMatrix: matrix_identity_float4x4
    )
}
