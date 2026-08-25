import Foundation
import CoreLocation
import simd

enum PointCloudFormat: String, CaseIterable, Identifiable {
    case ply = "PLY"
    case las = "LAS"

    var id: String { rawValue }
    var fileExtension: String {
        switch self {
        case .ply: return "ply"
        case .las: return "las"
        }
    }
}

struct PointCloudExportMetadata {
    var capturedAt: Date
    var location: CLLocationCoordinate2D?
    var pointCount: Int
}

/// A single exportable point: world-space position, the confidence value
/// captured alongside it (used as the PLY "confidence" property and, where
/// useful, mapped into LAS classification/intensity), and the real camera
/// color sampled at that pixel.
struct PointCloudExportPoint {
    var position: SIMD3<Float>
    var confidence: Float
    var color: SIMD3<Float> = SIMD3<Float>(0.5, 0.5, 0.5)
}
