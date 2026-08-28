import Foundation
import simd

/// Reads back the binary_little_endian PLY written by `PLYExporter` — the
/// two are a matched pair, not a general-purpose PLY parser.
///
/// Detects the file's schema generation from its header rather than
/// assuming one, so scans exported before a given field existed still load
/// instead of misreading past their actual vertex data:
/// - oldest: x, y, z, confidence only
/// - Fase 2: + RGB color
/// - Fase 4: + normal, classification
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

        let hasColor = header.contains("property uchar red")
        let hasNormalAndClassification = header.contains("property float nx")

        let floatSize = MemoryLayout<Float>.size
        let baseStride = floatSize * 4 // x, y, z, confidence
        let colorStride = hasColor ? 3 : 0
        let normalClassificationStride = hasNormalAndClassification ? (floatSize * 3 + 1) : 0
        let stride = baseStride + colorStride + normalClassificationStride

        let bodyStart = headerEndRange.upperBound
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

                var color = SIMD3<Float>(0.5, 0.5, 0.5)
                if hasColor {
                    let r = base.loadUnaligned(fromByteOffset: offset + 16, as: UInt8.self)
                    let g = base.loadUnaligned(fromByteOffset: offset + 17, as: UInt8.self)
                    let b = base.loadUnaligned(fromByteOffset: offset + 18, as: UInt8.self)
                    color = SIMD3(Float(r) / 255, Float(g) / 255, Float(b) / 255)
                }

                var normal = SIMD3<Float>(0, 1, 0)
                var classification: PointCloudMeshClassification = .none
                if hasNormalAndClassification {
                    let normalOffset = offset + baseStride + colorStride
                    let nx = base.loadUnaligned(fromByteOffset: normalOffset, as: Float.self)
                    let ny = base.loadUnaligned(fromByteOffset: normalOffset + 4, as: Float.self)
                    let nz = base.loadUnaligned(fromByteOffset: normalOffset + 8, as: Float.self)
                    normal = SIMD3(nx, ny, nz)
                    let classificationByte = base.loadUnaligned(fromByteOffset: normalOffset + 12, as: UInt8.self)
                    classification = PointCloudMeshClassification(rawValue: classificationByte) ?? .none
                }

                points.append(PointCloudExportPoint(
                    position: SIMD3(x, y, z),
                    confidence: confidence,
                    color: color,
                    normal: normal,
                    classification: classification
                ))
            }
        }

        return points
    }
}
