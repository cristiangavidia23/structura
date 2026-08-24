import Foundation

/// Async, off-main serialization of the Pro Scan point cloud into
/// enterprise export formats. Writes into `ScanStore.scansDirectory`, using
/// the existing scan's UUID so files round-trip alongside its USDZ/JSON.
actor PointCloudExportCoordinator {
    func export(
        points: [PointCloudExportPoint],
        metadata: PointCloudExportMetadata,
        format: PointCloudFormat,
        to directory: URL,
        baseName: String
    ) throws -> URL {
        switch format {
        case .ply:
            return try PLYExporter.write(points, metadata: metadata, to: directory, baseName: baseName)
        case .las:
            return try LASExporter.write(points, metadata: metadata, to: directory, baseName: baseName)
        }
    }
}
