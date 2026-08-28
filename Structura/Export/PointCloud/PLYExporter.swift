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

        var data = Data(header.utf8)
        // 7 floats (x,y,z,confidence,nx,ny,nz) + 3 uchar color + 1 uchar classification.
        data.reserveCapacity(data.count + points.count * (MemoryLayout<Float>.size * 7 + 4))

        for point in points {
            withUnsafeBytes(of: point.position.x) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: point.position.y) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: point.position.z) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: point.confidence) { data.append(contentsOf: $0) }
            data.append(UInt8(min(max(point.color.x * 255, 0), 255)))
            data.append(UInt8(min(max(point.color.y * 255, 0), 255)))
            data.append(UInt8(min(max(point.color.z * 255, 0), 255)))
            withUnsafeBytes(of: point.normal.x) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: point.normal.y) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: point.normal.z) { data.append(contentsOf: $0) }
            data.append(point.classification.rawValue)
        }

        let url = directory.appendingPathComponent("\(baseName).ply")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed(underlying: error)
        }
        return url
    }
}
