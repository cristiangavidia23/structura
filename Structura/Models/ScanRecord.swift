import Foundation

/// A snapshot of the Pro Scan capture's quality, taken alongside its final
/// export — the same numbers `ScanMetadataReport`'s JSON sidecar carries,
/// persisted here too so `ResultView` can show them without re-parsing a
/// PLY file that can hold hundreds of thousands of points.
struct PointCloudQualitySummary: Codable, Equatable {
    var durationSeconds: Int
    /// Same coarse categories as `ScanMetadataReport`: "buena" / "con
    /// interrupciones breves" / "con interrupciones frecuentes".
    var trackingQuality: String
    var pointCount: Int
    var meanConfidence: Float
}

struct ScanRecord: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    let createdAt: Date
    var usdzFileName: String
    var thumbnailFileName: String?
    var roomFileName: String

    /// Pro Scan point-cloud export artifacts, added by a later export pass.
    /// Absent (`nil`) on scans that never ran Pro Scan or were captured
    /// before this field existed — `Codable`'s default `decodeIfPresent`
    /// handling means old records simply decode these as `nil`.
    var plyFileName: String? = nil
    var lasFileName: String? = nil
    var pointCloudLatitude: Double? = nil
    var pointCloudLongitude: Double? = nil
    var pointCloudQuality: PointCloudQualitySummary? = nil
}
