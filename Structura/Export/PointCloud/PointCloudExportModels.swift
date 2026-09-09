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
///
/// `normal` and `classification` default to "no real data" values (`+Y up`,
/// `.none`) rather than being required, so the pre-Fase-3 construction
/// sites that don't supply them — `PLYPointCloudReader`, reading files
/// written before these fields existed — keep compiling unchanged.
struct PointCloudExportPoint {
    var position: SIMD3<Float>
    var confidence: Float
    var color: SIMD3<Float> = SIMD3<Float>(0.5, 0.5, 0.5)
    var normal: SIMD3<Float> = SIMD3<Float>(0, 1, 0)
    var classification: PointCloudMeshClassification = .none
    /// `false` when `confidence` above is a fallback value, not a real
    /// depth-pipeline observation (`VoxelAccumulator.Sample
    /// .isConfidenceObserved`, `ARPointCloudSession`'s `ConfidenceGrid`
    /// lookup) — Fase 2 of the architecture audit, finding E2: an exported
    /// file must be able to tell a real confidence reading apart from a
    /// number that only exists because *something* has to go in the field.
    /// `LASExporter` uses this to write an honest "no observation" sentinel
    /// into Intensity instead of a value indistinguishable from a real
    /// mid-confidence reading. Defaults to `true` so every pre-existing
    /// construction site (tests, `PLYPointCloudReader`) keeps compiling
    /// unchanged, per this struct's own established convention above.
    var isConfidenceObserved: Bool = true
}
