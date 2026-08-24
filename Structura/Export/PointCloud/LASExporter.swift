import Foundation

/// Minimal LAS 1.2 writer, point data record format 0 (no GPS time, no
/// color). Covers the 227-byte public header block plus fixed-length point
/// records — no LAZ compression, no VLR extras. No third-party dependency.
enum LASExporter {
    enum ExportError: Error {
        case emptyPointCloud
        case writeFailed
    }

    private static let headerSize: UInt16 = 227
    private static let pointRecordLength: UInt16 = 20
    private static let scaleFactor = 0.001 // millimeter precision

    static func write(_ points: [PointCloudExportPoint], metadata: PointCloudExportMetadata, to directory: URL, baseName: String) throws -> URL {
        guard !points.isEmpty else { throw ExportError.emptyPointCloud }

        var minX = Double(points[0].position.x), maxX = minX
        var minY = Double(points[0].position.y), maxY = minY
        var minZ = Double(points[0].position.z), maxZ = minZ
        for point in points {
            let x = Double(point.position.x), y = Double(point.position.y), z = Double(point.position.z)
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            minZ = min(minZ, z); maxZ = max(maxZ, z)
        }

        let offsetX = minX, offsetY = minY, offsetZ = minZ

        var data = Data(capacity: Int(headerSize) + points.count * Int(pointRecordLength))
        appendHeader(
            to: &data,
            pointCount: UInt32(points.count),
            scale: scaleFactor,
            offset: (offsetX, offsetY, offsetZ),
            bounds: (minX, maxX, minY, maxY, minZ, maxZ)
        )

        for point in points {
            let x = Int32(((Double(point.position.x) - offsetX) / scaleFactor).rounded())
            let y = Int32(((Double(point.position.y) - offsetY) / scaleFactor).rounded())
            let z = Int32(((Double(point.position.z) - offsetZ) / scaleFactor).rounded())
            let intensity = UInt16(max(0, min(65535, point.confidence * 65535)))

            appendLE(&data, x)
            appendLE(&data, y)
            appendLE(&data, z)
            appendLE(&data, intensity)
            data.append(0) // return number / number of returns / flags
            data.append(0) // classification
            data.append(0) // scan angle rank
            data.append(0) // user data
            appendLE(&data, UInt16(0)) // point source ID
        }

        let url = directory.appendingPathComponent("\(baseName).las")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed
        }
        return url
    }

    private static func appendHeader(
        to data: inout Data,
        pointCount: UInt32,
        scale: Double,
        offset: (Double, Double, Double),
        bounds: (Double, Double, Double, Double, Double, Double)
    ) {
        data.append(contentsOf: Array("LASF".utf8))              // File signature
        appendLE(&data, UInt16(0))                                // File source ID
        appendLE(&data, UInt16(0))                                // Global encoding
        data.append(contentsOf: [UInt8](repeating: 0, count: 16)) // Project ID GUID
        data.append(1)                                            // Version major
        data.append(2)                                            // Version minor
        appendFixedString("Structura", length: 32, to: &data)     // System identifier
        appendFixedString("Structura Pro Scan", length: 32, to: &data) // Generating software
        appendLE(&data, UInt16(1))                                // File creation day of year
        appendLE(&data, UInt16(Calendar.current.component(.year, from: Date()))) // Creation year
        appendLE(&data, headerSize)                               // Header size
        appendLE(&data, UInt32(headerSize))                       // Offset to point data
        appendLE(&data, UInt32(0))                                // Number of VLRs
        data.append(0)                                            // Point data record format
        appendLE(&data, pointRecordLength)                        // Point data record length
        appendLE(&data, pointCount)                                // Number of point records (legacy)
        for _ in 0..<5 { appendLE(&data, UInt32(0)) }              // Number of points by return
        appendLE(&data, scale); appendLE(&data, scale); appendLE(&data, scale) // Scale factors
        appendLE(&data, offset.0); appendLE(&data, offset.1); appendLE(&data, offset.2) // Offsets
        appendLE(&data, bounds.1); appendLE(&data, bounds.0) // max X, min X
        appendLE(&data, bounds.3); appendLE(&data, bounds.2) // max Y, min Y
        appendLE(&data, bounds.5); appendLE(&data, bounds.4) // max Z, min Z
    }

    private static func appendFixedString(_ string: String, length: Int, to data: inout Data) {
        var bytes = Array(string.utf8.prefix(length))
        while bytes.count < length { bytes.append(0) }
        data.append(contentsOf: bytes)
    }

    private static func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendLE(_ data: inout Data, _ value: Double) {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }
}
