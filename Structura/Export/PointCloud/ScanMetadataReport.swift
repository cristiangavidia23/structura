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
    /// Mean confidence **over points with a real observation only**
    /// (`PointCloudExportPoint.isConfidenceObserved == true`) — Fase 2 of
    /// the architecture audit, finding E2. Averaging in every fallback
    /// value alongside real ones (the pre-Fase-2 behavior) silently pulled
    /// this number toward whatever the fallback constant was, regardless
    /// of how much of the scan that fallback actually covered; see
    /// `unobservedConfidencePointFraction` below for that coverage number
    /// instead. `0` if there are no observed points at all, matching this
    /// field's pre-existing "empty scan" convention.
    var meanConfidence: Float
    /// Fraction (0...1) of `pointCount` whose confidence is a fallback
    /// value, not a real depth-pipeline observation — the number
    /// `meanConfidence` above does *not* cover. `0` means every exported
    /// point carries a genuine confidence reading; closer to `1` means most
    /// of the scan's confidence data is a placeholder, which is itself a
    /// signal the depth-pipeline coverage (`ProScanConfig.depthSampleHz`/
    /// `depthPixelStride`) may need to be higher for scans like this one.
    var unobservedConfidencePointFraction: Double
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
        // Fase 2, finding E2: averaged only over points with a real
        // observation — see this field's doc comment.
        let observedPoints = points.filter(\.isConfidenceObserved)
        let meanConfidence: Float = observedPoints.isEmpty
            ? 0
            : observedPoints.reduce(Float(0)) { $0 + $1.confidence } / Float(observedPoints.count)
        let unobservedConfidencePointFraction: Double = points.isEmpty
            ? 0
            : Double(points.count - observedPoints.count) / Double(points.count)

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
            unobservedConfidencePointFraction: unobservedConfidencePointFraction,
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
