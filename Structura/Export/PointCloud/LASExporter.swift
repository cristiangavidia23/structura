import Foundation
import simd

/// LAS 1.4 writer, Point Data Record Format 7 (X/Y/Z, intensity, return
/// info, classification, scan angle, point source ID, GPS time, RGB). The
/// 375-byte public header, the 36-byte point record, the classification
/// codes, and the required OGC WKT coordinate-system VLR are all verified
/// byte-for-byte against the official ASPRS "LAS Specification 1.4 - R15"
/// (asprs.org) — not reconstructed from memory. No third-party dependency,
/// no LAZ compression.
///
/// Coordinate systems: positions arrive in ARKit's right-handed +Y-up
/// world space; every point is rotated to the right-handed +Z-up
/// convention civil/CAD tooling expects (see `TopographicAxisConvention`)
/// before being scaled/offset into the LAS integer record. This is the one
/// Pro Scan export format meant to leave the app and enter external survey
/// tooling directly, so it's the one that performs this conversion — see
/// `PLYExporter`, which deliberately does not.
enum LASExporter {
    enum ExportError: Error, LocalizedError {
        case emptyPointCloud
        case writeFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .emptyPointCloud:
                return "La nube de puntos está vacía; no hay nada que exportar."
            case .writeFailed(let underlying):
                return "No se pudo escribir el archivo LAS: \(underlying.localizedDescription)"
            }
        }
    }

    /// LAS 1.4 §2.4, Table 3: fixed at 375 bytes for this version — "The
    /// Public Header Block may not be extended by users."
    static let headerSize: UInt16 = 375
    /// LAS 1.4 §2.6.8, Table 18: Point Data Record Format 7's minimum size.
    static let pointRecordLength: UInt16 = 36
    private static let pointDataRecordFormat: UInt8 = 7

    /// OGC Coordinate System WKT VLR identity (LAS 1.4 §3.2.2) — verified
    /// against the spec PDF, not the newer/incompatible LAS 1.5 convention
    /// (which uses a different User ID/Record ID scheme entirely).
    private static let wktVLRUserID = "LASF_Projection"
    private static let wktVLRRecordID: UInt16 = 2112
    static let vlrHeaderSize = 54

    static func write(
        _ points: [PointCloudExportPoint],
        metadata: PointCloudExportMetadata,
        controlPoint: ControlPointTransform? = nil,
        to directory: URL,
        baseName: String
    ) throws -> URL {
        guard !points.isEmpty else { throw ExportError.emptyPointCloud }

        // Rotate every point into the Z-up frame Civil3D/CAD tooling
        // expects before computing bounds/scaling — the bounds must
        // reflect the coordinates actually written, not the pre-rotation
        // ARKit ones. `controlPoint`, if supplied, then shifts the origin
        // to a real site coordinate (translation only — see
        // `ControlPointTransform`'s doc comment).
        let rotatedPositions = points.map { point -> SIMD3<Float> in
            let zUp = TopographicAxisConvention.convert(point.position)
            return controlPoint.map { $0.apply(zUp) } ?? zUp
        }

        var minX = Double(rotatedPositions[0].x), maxX = minX
        var minY = Double(rotatedPositions[0].y), maxY = minY
        var minZ = Double(rotatedPositions[0].z), maxZ = minZ
        for position in rotatedPositions {
            let x = Double(position.x), y = Double(position.y), z = Double(position.z)
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            minZ = min(minZ, z); maxZ = max(maxZ, z)
        }

        let scale = ProScanConfig.lasScaleFactorMeters
        let offsetX = minX, offsetY = minY, offsetZ = minZ

        let wkt = controlPoint.map { LocalEngineeringCRS.wktDescriptionAnchoredToControlPoint(declaredAccuracyMeters: $0.declaredAccuracyMeters) }
            ?? LocalEngineeringCRS.wktDescription
        let vlrBodySize = wkt.utf8.count + 1 // null-terminated, per LAS 1.4 §3.2.2
        let vlrTotalSize = vlrHeaderSize + vlrBodySize

        var data = Data(capacity: Int(headerSize) + vlrTotalSize + points.count * Int(pointRecordLength))

        appendHeader(
            to: &data,
            pointCount: UInt64(points.count),
            scale: scale,
            offset: (offsetX, offsetY, offsetZ),
            bounds: (minX, maxX, minY, maxY, minZ, maxZ),
            offsetToPointData: UInt32(Int(headerSize) + vlrTotalSize),
            capturedAt: metadata.capturedAt
        )
        appendWKTVLR(to: &data, wkt: wkt)

        let gpsTime = standardGPSTime(for: metadata.capturedAt)
        for (index, point) in points.enumerated() {
            let position = rotatedPositions[index]
            let x = Int32(((Double(position.x) - offsetX) / scale).rounded())
            let y = Int32(((Double(position.y) - offsetY) / scale).rounded())
            let z = Int32(((Double(position.z) - offsetZ) / scale).rounded())
            let intensity = UInt16(clamping: Int((point.confidence * 65535).rounded()))

            appendLE(&data, x)
            appendLE(&data, y)
            appendLE(&data, z)
            appendLE(&data, intensity)
            // Return Number=1 (bits 0-3), Number of Returns=1 (bits 4-7):
            // every fused mesh point is its own single return. Fixes the
            // audit's finding that this byte was always 0 — which silently
            // discards every point under a standard `return_number == 1`
            // first-return filter, the routine way civil workflows extract
            // a surface from a point cloud.
            data.append(0x11)
            // Classification Flags / Scanner Channel / Scan Direction /
            // Edge of Flight Line — none apply to a fused mesh vertex.
            data.append(0x00)
            data.append(point.classification.lasClassificationCode)
            data.append(0) // User Data
            // Scan Angle: no single originating pulse angle exists for a
            // fused mesh vertex. The spec's own guidance for "Aggregate
            // Model Systems" (LAS 1.4 §2.6.7) is to set this to zero unless
            // assigned from a component measurement — exactly this case.
            appendLE(&data, Int16(0))
            appendLE(&data, UInt16(0)) // Point Source ID — single source
            appendLE(&data, gpsTime)
            appendLE(&data, UInt16(clamping: Int((point.color.x * 65535).rounded())))
            appendLE(&data, UInt16(clamping: Int((point.color.y * 65535).rounded())))
            appendLE(&data, UInt16(clamping: Int((point.color.z * 65535).rounded())))
        }

        let url = directory.appendingPathComponent("\(baseName).las")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed(underlying: error)
        }
        return url
    }

    private static func appendHeader(
        to data: inout Data,
        pointCount: UInt64,
        scale: Double,
        offset: (Double, Double, Double),
        bounds: (Double, Double, Double, Double, Double, Double),
        offsetToPointData: UInt32,
        capturedAt: Date
    ) {
        data.append(contentsOf: Array("LASF".utf8))                       // File Signature — 4 @0
        appendLE(&data, UInt16(0))                                        // File Source ID — 2 @4
        // Global Encoding: bit 0 = 1 (GPS Time is Standard/Adjusted, not
        // GPS Week Time) — bit 4 = 1 (CRS is WKT — required for PDRF 6-10,
        // LAS 1.4 §3.1: "Point Data Record Formats 6-10 must use WKT").
        appendLE(&data, UInt16(0b1_0001))                                 // Global Encoding — 2 @6
        appendLE(&data, UInt32(0))                                        // Project ID GUID 1 — 4 @8
        appendLE(&data, UInt16(0))                                        // Project ID GUID 2 — 2 @12
        appendLE(&data, UInt16(0))                                        // Project ID GUID 3 — 2 @14
        data.append(contentsOf: [UInt8](repeating: 0, count: 8))          // Project ID GUID 4 — 8 @16
        data.append(1)                                                   // Version Major — 1 @24
        data.append(4)                                                   // Version Minor — 1 @25
        appendFixedString("Structura", length: 32, to: &data)             // System Identifier — 32 @26
        appendFixedString("Structura Pro Scan", length: 32, to: &data)    // Generating Software — 32 @58
        let (dayOfYear, year) = utcDayOfYearAndYear(for: capturedAt)
        appendLE(&data, UInt16(dayOfYear))                                // File Creation Day of Year — 2 @90
        appendLE(&data, UInt16(year))                                     // File Creation Year — 2 @92
        appendLE(&data, headerSize)                                       // Header Size — 2 @94
        appendLE(&data, offsetToPointData)                                // Offset to Point Data — 4 @96
        appendLE(&data, UInt32(1))                                        // Number of VLRs — 4 @100 (just the WKT VLR)
        data.append(pointDataRecordFormat)                                // Point Data Record Format — 1 @104
        appendLE(&data, pointRecordLength)                                // Point Data Record Length — 2 @105
        // Legacy fields: LAS 1.4 §2.4 requires these be zero whenever the
        // Point Data Record Format is 6 or higher (as PDRF 7 always is
        // here) — the real count lives only in the 1.4-native 8-byte
        // fields near the end of the header.
        appendLE(&data, UInt32(0))                                        // Legacy Number of Point Records — 4 @107
        for _ in 0..<5 { appendLE(&data, UInt32(0)) }                      // Legacy Number of Points by Return — 20 @111
        appendLE(&data, scale); appendLE(&data, scale); appendLE(&data, scale)          // X/Y/Z Scale Factor — 24 @131
        appendLE(&data, offset.0); appendLE(&data, offset.1); appendLE(&data, offset.2) // X/Y/Z Offset — 24 @155
        appendLE(&data, bounds.1); appendLE(&data, bounds.0)               // Max X, Min X — 16 @179
        appendLE(&data, bounds.3); appendLE(&data, bounds.2)               // Max Y, Min Y — 16 @195
        appendLE(&data, bounds.5); appendLE(&data, bounds.4)               // Max Z, Min Z — 16 @211
        appendLE(&data, UInt64(0))                                        // Start of Waveform Data Packet Record — 8 @227
        appendLE(&data, UInt64(0))                                        // Start of First Extended VLR — 8 @235 (none)
        appendLE(&data, UInt32(0))                                        // Number of Extended VLRs — 4 @243
        appendLE(&data, pointCount)                                       // Number of Point Records — 8 @247
        appendLE(&data, pointCount)                                       // Number of Points by Return[0] — 8 @255 (every point is 1-of-1)
        for _ in 0..<14 { appendLE(&data, UInt64(0)) }                     // Number of Points by Return[1...14] — 112 @263
        // Total: 375 bytes (@375 = end of header), verified against the spec.
    }

    private static func appendWKTVLR(to data: inout Data, wkt: String) {
        appendLE(&data, UInt16(0))                                        // Reserved — 2
        appendFixedString(wktVLRUserID, length: 16, to: &data)             // User ID — 16
        appendLE(&data, wktVLRRecordID)                                   // Record ID — 2
        let wktBytes = Array(wkt.utf8) + [0]                              // null-terminated, LAS 1.4 §3.2.2
        appendLE(&data, UInt16(wktBytes.count))                           // Record Length After Header — 2
        appendFixedString("OGC Coordinate System WKT", length: 32, to: &data) // Description — 32
        data.append(contentsOf: wktBytes)
    }

    /// "Adjusted Standard GPS Time" (LAS 1.4 §2.4, Global Encoding bit 0):
    /// seconds since the GPS epoch (00:00:00 UTC, January 6 1980), minus
    /// 1×10⁹ to keep the value near zero for floating-point resolution.
    /// Does **not** correct for the UTC/GPS leap-second offset (~18 s as of
    /// the last announced leap second) — acceptable for what this field is
    /// actually used for here (a capture-time provenance record, not
    /// multi-sensor-synchronized survey timing), but not truly synchronized
    /// GPS time. `ScanMetadataReport` states the real capture date/time
    /// separately, in plain UTC, for anything that needs it exactly.
    static func standardGPSTime(for date: Date) -> Double {
        let gpsEpoch = Date(timeIntervalSince1970: 315_964_800) // 1980-01-06T00:00:00Z
        return date.timeIntervalSince(gpsEpoch) - 1_000_000_000
    }

    /// LAS 1.4 requires GMT/UTC day-of-year and year, not local time —
    /// fixes the prior exporter's hardcoded day-of-year of 1.
    static func utcDayOfYearAndYear(for date: Date) -> (dayOfYear: Int, year: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        let year = calendar.component(.year, from: date)
        return (dayOfYear, year)
    }

    private static func appendFixedString(_ string: String, length: Int, to data: inout Data) {
        var bytes = Array(string.utf8.prefix(length))
        while bytes.count < length { bytes.append(0) }
        data.append(contentsOf: bytes)
    }

    static func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    static func appendLE(_ data: inout Data, _ value: Double) {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }
}

extension PointCloudMeshClassification {
    /// ASPRS standard point classification codes (LAS 1.4 §2.6.7, Table
    /// 17, verified against the spec PDF): 1=Unclassified, 2=Ground,
    /// 6=Building, 64-255=User Definable. Mapped per the Pro Scan plan:
    /// floors are the closest real-world match to Ground, structural
    /// surfaces map to Building, furniture goes in the user-definable
    /// range with distinct codes so they stay distinguishable, and
    /// anything with no real classification signal stays honestly
    /// Unclassified rather than a fabricated guess.
    var lasClassificationCode: UInt8 {
        switch self {
        case .none: return 1
        case .floor: return 2
        case .wall, .ceiling, .window, .door: return 6
        case .table: return 64
        case .seat: return 65
        }
    }
}
