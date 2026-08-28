import Foundation

/// A JSON sidecar written alongside every Pro Scan export: the numbers an
/// engineer needs to judge whether a scan is usable before ever opening the
/// point cloud itself — device, capture duration and tracking quality,
/// point count and density, mean confidence, units, and the coordinate
/// reference system actually declared in the accompanying `.las` file.
struct ScanMetadataReport: Codable {
    var device: String
    var systemVersion: String
    var capturedAt: Date
    var durationSeconds: Int
    /// A coarse, honest signal — "buena" / "con interrupciones breves" /
    /// "con interrupciones frecuentes" / "sin datos" — derived from a
    /// once-a-second sample of tracking state, not a continuous integral.
    /// Full per-session tracking-quality history (surfaced in the app's
    /// own UI, not just this file) is a later phase's job.
    var trackingQuality: String
    var pointCount: Int
    /// Points per m² of horizontal bounding-box area, in ARKit's own
    /// frame — a coarse coverage proxy, not a real triangulated-surface
    /// density. `nil` if the scan has no horizontal extent at all.
    var pointDensityPerSquareMeter: Double?
    var meanConfidence: Float
    var units: String
    var coordinateReferenceSystem: String
    /// Declared accuracy of the control-point anchor, in meters, if one was
    /// supplied. `nil` for the default local-frame export.
    var controlPointDeclaredAccuracyMeters: Double?

    static func make(
        points: [PointCloudExportPoint],
        metadata: PointCloudExportMetadata,
        durationSeconds: Int,
        trackingDegradedTickCount: Int,
        coordinateReferenceSystem: String,
        controlPointDeclaredAccuracyMeters: Double? = nil
    ) -> ScanMetadataReport {
        let meanConfidence: Float = points.isEmpty
            ? 0
            : points.reduce(Float(0)) { $0 + $1.confidence } / Float(points.count)

        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minZ = Float.greatestFiniteMagnitude, maxZ = -Float.greatestFiniteMagnitude
        for point in points {
            minX = min(minX, point.position.x); maxX = max(maxX, point.position.x)
            minZ = min(minZ, point.position.z); maxZ = max(maxZ, point.position.z)
        }
        // X and Z are the two horizontal axes in ARKit's own +Y-up frame
        // (before `TopographicAxisConvention` rotates for LAS).
        let horizontalArea = points.isEmpty ? 0 : Double(max(maxX - minX, 0)) * Double(max(maxZ - minZ, 0))
        let density: Double? = horizontalArea > 0 ? Double(points.count) / horizontalArea : nil

        let trackingQuality: String
        if durationSeconds <= 0 {
            trackingQuality = "sin datos"
        } else {
            let degradedFraction = Double(trackingDegradedTickCount) / Double(durationSeconds)
            if degradedFraction < 0.05 {
                trackingQuality = "buena"
            } else if degradedFraction < 0.25 {
                trackingQuality = "con interrupciones breves"
            } else {
                trackingQuality = "con interrupciones frecuentes"
            }
        }

        return ScanMetadataReport(
            device: deviceModelIdentifier(),
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            capturedAt: metadata.capturedAt,
            durationSeconds: durationSeconds,
            trackingQuality: trackingQuality,
            pointCount: points.count,
            pointDensityPerSquareMeter: density,
            meanConfidence: meanConfidence,
            units: "meters",
            coordinateReferenceSystem: coordinateReferenceSystem,
            controlPointDeclaredAccuracyMeters: controlPointDeclaredAccuracyMeters
        )
    }

    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        return machineMirror.children.reduce(into: "") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            identifier += String(UnicodeScalar(UInt8(value)))
        }
    }

    @discardableResult
    func write(to directory: URL, baseName: String) throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let url = directory.appendingPathComponent("\(baseName)_metadata.json")
        try data.write(to: url, options: .atomic)
        return url
    }
}
