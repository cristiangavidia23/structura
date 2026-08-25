import Foundation
import simd

/// Reads back the binary_little_endian PLY written by `PLYExporter` — the
/// two are a matched pair, not a general-purpose PLY parser.
enum PLYPointCloudReader {
    static func read(from url: URL) -> [PointCloudExportPoint]? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        guard let headerEndRange = data.range(of: Data("end_header\n".utf8)) else { return nil }
        let headerData = data[..<headerEndRange.lowerBound]
        guard let header = String(data: headerData, encoding: .utf8) else { return nil }

        var vertexCount = 0
        for line in header.split(separator: "\n") {
            if line.hasPrefix("element vertex") {
                vertexCount = Int(line.split(separator: " ").last ?? "") ?? 0
            }
        }
        guard vertexCount > 0 else { return nil }

        let bodyStart = headerEndRange.upperBound
        let stride = MemoryLayout<Float>.size * 4 // x, y, z, confidence
        guard data.count - bodyStart >= vertexCount * stride else { return nil }

        var points: [PointCloudExportPoint] = []
        points.reserveCapacity(vertexCount)

        data.withUnsafeBytes { rawBuffer in
            let base = rawBuffer.baseAddress!.advanced(by: bodyStart)
            for i in 0..<vertexCount {
                let offset = i * stride
                let x = base.loadUnaligned(fromByteOffset: offset, as: Float.self)
                let y = base.loadUnaligned(fromByteOffset: offset + 4, as: Float.self)
                let z = base.loadUnaligned(fromByteOffset: offset + 8, as: Float.self)
                let confidence = base.loadUnaligned(fromByteOffset: offset + 12, as: Float.self)
                points.append(PointCloudExportPoint(position: SIMD3(x, y, z), confidence: confidence))
            }
        }

        return points
    }
}
