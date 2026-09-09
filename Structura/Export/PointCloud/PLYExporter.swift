import Foundation

/// Writes a binary_little_endian PLY: x/y/z position, confidence, RGB
/// color, per-vertex normal, and a classification byte. No third-party
/// dependency — operates on plain point/metadata types, no ARKit/Metal
/// types involved.
///
/// Stays in ARKit's native +Y-up frame — unlike `LASExporter`, which
/// rotates to +Z-up for CAD/survey tooling — since this format is read
/// back by the in-app SceneKit viewer (`PLYPointCloudReader`,
/// `PointCloudSceneView`) and by axis-convention-agnostic tools like
/// CloudCompare/MeshLab, neither of which benefit from the rotation.
///
/// `PLYPointCloudReader` is this file's matched pair, not a general-purpose
/// PLY parser — the two are updated together whenever this schema changes,
/// as they are here (adding `normal`/`classification`).
///
/// # Streamed to disk (Fase 1 of the architecture audit, finding C7)
///
/// The previous version built the *entire* file as one in-memory `Data`
/// before writing it: a peak allocation the size of the whole export, on
/// top of the point array itself — and this exporter is what
/// `ProScanCaptureView`'s autosave calls every
/// `ProScanConfig.autosaveIntervalSeconds`, on a scan that can hold up to
/// `ProScanConfig.maximumMeshPointBudget` points. `write(_:metadata:to:
/// baseName:)` now streams the point data through a fixed-size buffer,
/// flushed to a `FileHandle` every `pointsPerBatch` points, so the peak
/// in-flight buffer stays a few hundred KB regardless of scan size.
enum PLYExporter {
    enum ExportError: Error, LocalizedError {
        case emptyPointCloud
        case writeFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .emptyPointCloud:
                return "La nube de puntos está vacía; no hay nada que exportar."
            case .writeFailed(let underlying):
                return "No se pudo escribir el archivo PLY: \(underlying.localizedDescription)"
            }
        }
    }

    /// One vertex record's byte size, matching the header's `property`
    /// list exactly: 7 floats (x, y, z, confidence, nx, ny, nz) + 3 uchar
    /// color + 1 uchar classification.
    private static let bytesPerPoint = MemoryLayout<Float>.size * 7 + 4

    /// Points per flush to the `FileHandle`. Large enough to amortize the
    /// write-syscall cost across many points, small enough that the
    /// in-flight buffer (`pointsPerBatch * bytesPerPoint`, ~256 KB at this
    /// size) never approaches the size of the export itself. Not derived
    /// from measurement — a reasonable starting point, like several other
    /// engineering constants in this pipeline (see `ProScanConfig`).
    private static let pointsPerBatch = 8192

    static func write(_ points: [PointCloudExportPoint], metadata: PointCloudExportMetadata, to directory: URL, baseName: String) throws -> URL {
        guard !points.isEmpty else { throw ExportError.emptyPointCloud }

        let header = """
        ply
        format binary_little_endian 1.0
        comment Structura Pro Scan export
        comment captured_at \(ISO8601DateFormatter().string(from: metadata.capturedAt))
        element vertex \(points.count)
        property float x
        property float y
        property float z
        property float confidence
        property uchar red
        property uchar green
        property uchar blue
        property float nx
        property float ny
        property float nz
        property uchar classification
        end_header

        """

        let url = directory.appendingPathComponent("\(baseName).ply")
        // Streamed to a sibling temp file, then moved into place — same
        // directory, so the move is a same-volume rename and therefore
        // atomic, matching the all-or-nothing guarantee the previous
        // `Data.write(options: .atomic)` gave, without needing the whole
        // file in memory to get it. This matters specifically because
        // autosave overwrites this exact filename every few seconds during
        // a live capture: a reader (the in-app PLY viewer, opened after the
        // fact) must never be able to observe a half-written file.
        let temporaryURL = directory.appendingPathComponent("\(baseName).ply.\(UUID().uuidString).tmp")

        do {
            try writeStreaming(points, header: header, to: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw ExportError.writeFailed(underlying: error)
        }

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw ExportError.writeFailed(underlying: error)
        }

        return url
    }

    /// Streams `points` to `url` in fixed-size batches. Throws (rather than
    /// silently truncating) on any I/O failure partway through — the caller
    /// above removes the partial temp file either way, so a failure here
    /// never leaves a corrupt file at the real destination.
    private static func writeStreaming(_ points: [PointCloudExportPoint], header: String, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ExportError.writeFailed(underlying: CocoaError(.fileWriteUnknown))
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        try handle.write(contentsOf: Data(header.utf8))

        var buffer = Data(capacity: pointsPerBatch * bytesPerPoint)
        var pointsInBuffer = 0

        for point in points {
            withUnsafeBytes(of: point.position.x) { buffer.append(contentsOf: $0) }
            withUnsafeBytes(of: point.position.y) { buffer.append(contentsOf: $0) }
            withUnsafeBytes(of: point.position.z) { buffer.append(contentsOf: $0) }
            withUnsafeBytes(of: point.confidence) { buffer.append(contentsOf: $0) }
            buffer.append(UInt8(min(max(point.color.x * 255, 0), 255)))
            buffer.append(UInt8(min(max(point.color.y * 255, 0), 255)))
            buffer.append(UInt8(min(max(point.color.z * 255, 0), 255)))
            withUnsafeBytes(of: point.normal.x) { buffer.append(contentsOf: $0) }
            withUnsafeBytes(of: point.normal.y) { buffer.append(contentsOf: $0) }
            withUnsafeBytes(of: point.normal.z) { buffer.append(contentsOf: $0) }
            buffer.append(point.classification.rawValue)
            pointsInBuffer += 1

            if pointsInBuffer >= pointsPerBatch {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                pointsInBuffer = 0
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
    }
}
