import Foundation

/// Async, off-main serialization of the Pro Scan point cloud into
/// enterprise export formats. Writes into `ScanStore.scansDirectory`, using
/// the existing scan's UUID so files round-trip alongside its USDZ/JSON.
actor PointCloudExportCoordinator {
    /// `controlPoint` only affects `.las` — `PLYExporter` deliberately
    /// stays in ARKit's native frame (see its doc comment), so a control
    /// point (defined in the +Z-up frame `LASExporter` writes) has nothing
    /// to apply to.
    func export(
        points: [PointCloudExportPoint],
        metadata: PointCloudExportMetadata,
        format: PointCloudFormat,
        controlPoint: ControlPointTransform? = nil,
        to directory: URL,
        baseName: String
    ) throws -> URL {
        switch format {
        case .ply:
            return try PLYExporter.write(points, metadata: metadata, to: directory, baseName: baseName)
        case .las:
            return try LASExporter.write(points, metadata: metadata, controlPoint: controlPoint, to: directory, baseName: baseName)
        }
    }

    /// Builds and writes the `ScanMetadataReport` sidecar, returning the
    /// report itself (not just its file URL) so callers can persist the
    /// same numbers elsewhere — `ProScanCaptureView` mirrors a subset onto
    /// `ScanRecord.pointCloudQuality` — without recomputing them. Takes the
    /// raw point array (not a pre-built report) so the mean-confidence/
    /// bounding-box pass over every point — the same "never on the main
    /// thread" rule as the binary exporters — happens on this actor, not
    /// on the caller's context.
    @discardableResult
    func writeMetadataReport(
        points: [PointCloudExportPoint],
        metadata: PointCloudExportMetadata,
        durationSeconds: Int,
        trackingDegradedTickCount: Int,
        coordinateReferenceSystem: String,
        controlPointDeclaredAccuracyMeters: Double?,
        to directory: URL,
        baseName: String
    ) throws -> ScanMetadataReport {
        let report = ScanMetadataReport.make(
            points: points,
            metadata: metadata,
            durationSeconds: durationSeconds,
            trackingDegradedTickCount: trackingDegradedTickCount,
            coordinateReferenceSystem: coordinateReferenceSystem,
            controlPointDeclaredAccuracyMeters: controlPointDeclaredAccuracyMeters
        )
        try report.write(to: directory, baseName: baseName)
        return report
    }
}
