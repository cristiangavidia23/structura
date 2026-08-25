import Foundation

/// Writes a binary_little_endian PLY: x/y/z position plus a confidence
/// property per vertex. No third-party dependency — operates on plain
/// point/metadata types, no ARKit/Metal types involved.
enum PLYExporter {
    enum ExportError: Error {
        case emptyPointCloud
        case writeFailed
    }

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
        end_header

        """

        var data = Data(header.utf8)
        data.reserveCapacity(data.count + points.count * (MemoryLayout<Float>.size * 4 + 3))

        for point in points {
            withUnsafeBytes(of: point.position.x) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: point.position.y) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: point.position.z) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: point.confidence) { data.append(contentsOf: $0) }
            data.append(UInt8(min(max(point.color.x * 255, 0), 255)))
            data.append(UInt8(min(max(point.color.y * 255, 0), 255)))
            data.append(UInt8(min(max(point.color.z * 255, 0), 255)))
        }

        let url = directory.appendingPathComponent("\(baseName).ply")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed
        }
        return url
    }
}
