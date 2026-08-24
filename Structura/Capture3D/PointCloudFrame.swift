import Foundation
import simd

/// One processed snapshot of dense scene points: unprojected positions plus
/// a matching per-point confidence value in [0, 1]. Built off the main
/// thread from `ARFrame.sceneDepth`; never retains the source `ARFrame`.
struct PointCloudFrame: Sendable {
    var positions: [SIMD3<Float>]
    var confidences: [Float]
    var timestamp: TimeInterval

    static let empty = PointCloudFrame(positions: [], confidences: [], timestamp: 0)
}
