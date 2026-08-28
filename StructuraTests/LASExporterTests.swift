import Foundation
import simd
import XCTest

/// Byte-offset and precision acceptance tests for `LASExporter`, per the
/// Fase 4 verification plan. Every offset checked here is quoted directly
/// from the official ASPRS "LAS Specification 1.4 - R15" (asprs.org,
/// verified against the PDF, §2.4 Table 3 and §2.6.8 Table 18) — this test
/// is what actually proves the header is byte-perfect, not just that the
/// exporter agrees with itself.
final class LASExporterTests: XCTestCase {

    private func writeTempLAS(_ points: [PointCloudExportPoint]) throws -> (url: URL, data: Data) {
        let metadata = PointCloudExportMetadata(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), location: nil, pointCount: points.count)
        let baseName = "las_test_\(UUID().uuidString)"
        let url = try LASExporter.write(points, metadata: metadata, to: FileManager.default.temporaryDirectory, baseName: baseName)
        let data = try Data(contentsOf: url)
        return (url, data)
    }

    private func loadLE<T>(_ data: Data, at offset: Int, as type: T.Type) -> T {
        data.withUnsafeBytes { $0.baseAddress!.advanced(by: offset).loadUnaligned(as: T.self) }
    }

    // MARK: - Public Header Block, byte-offset verified against the spec

    func testHeaderFieldsAtTheirSpecifiedByteOffsets() throws {
        let points = [
            PointCloudExportPoint(position: SIMD3<Float>(0, 0, 0), confidence: 1.0),
            PointCloudExportPoint(position: SIMD3<Float>(1, 2, 3), confidence: 0.5),
        ]
        let (url, data) = try writeTempLAS(points)
        defer { try? FileManager.default.removeItem(at: url) }

        // File Signature — offset 0, 4 bytes.
        XCTAssertEqual(data.subdata(in: 0..<4), Data("LASF".utf8))
        // File Source ID — offset 4, unsigned short.
        XCTAssertEqual(loadLE(data, at: 4, as: UInt16.self), 0)
        // Global Encoding — offset 6: bit0 (Standard GPS Time) + bit4 (WKT) set.
        XCTAssertEqual(loadLE(data, at: 6, as: UInt16.self), 0b1_0001)
        // Version Major/Minor — offsets 24/25.
        XCTAssertEqual(data[24], 1)
        XCTAssertEqual(data[25], 4)
        // Header Size — offset 94, must be exactly 375 for LAS 1.4.
        XCTAssertEqual(loadLE(data, at: 94, as: UInt16.self), 375)
        // Point Data Record Format — offset 104, must be 7.
        XCTAssertEqual(data[104], 7)
        // Point Data Record Length — offset 105, must be 36 (PDRF 7 minimum).
        XCTAssertEqual(loadLE(data, at: 105, as: UInt16.self), 36)
        // Legacy Number of Point Records — offset 107: must be zero, PDRF >= 6.
        XCTAssertEqual(loadLE(data, at: 107, as: UInt32.self), 0)
        // Legacy Number of Points by Return[5] — offset 111, 20 bytes: all zero.
        for i in stride(from: 111, to: 131, by: 4) {
            XCTAssertEqual(loadLE(data, at: i, as: UInt32.self), 0, "Legacy points-by-return must be zero at offset \(i).")
        }
        // Number of Point Records — offset 247, unsigned long long (the
        // *real*, 1.4-native point count field).
        XCTAssertEqual(loadLE(data, at: 247, as: UInt64.self), 2)
        // Number of Points by Return[0] — offset 255: every point is a
        // first-of-1 return, so this equals the total point count.
        XCTAssertEqual(loadLE(data, at: 255, as: UInt64.self), 2)
        // Number of Points by Return[1...14] — offsets 263...367, 112 bytes: all zero.
        for i in stride(from: 263, to: 375, by: 8) {
            XCTAssertEqual(loadLE(data, at: i, as: UInt64.self), 0, "Points-by-return[>0] must be zero at offset \(i).")
        }
    }

    // MARK: - Required WKT VLR (LAS 1.4 §3.1: PDRF 6-10 must use WKT)

    func testWKTVLRIsPresentAtTheExpectedIdentityAndOffset() throws {
        let points = [PointCloudExportPoint(position: SIMD3<Float>(0, 0, 0), confidence: 1.0)]
        let (url, data) = try writeTempLAS(points)
        defer { try? FileManager.default.removeItem(at: url) }

        // Number of VLRs — offset 100: exactly one (the WKT VLR).
        XCTAssertEqual(loadLE(data, at: 100, as: UInt32.self), 1)

        let vlrStart = 375
        // Reserved — 2 bytes.
        XCTAssertEqual(loadLE(data, at: vlrStart, as: UInt16.self), 0)
        // User ID — 16 bytes, null-padded ASCII.
        let userIDBytes = data.subdata(in: (vlrStart + 2)..<(vlrStart + 18))
        let userID = String(decoding: userIDBytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        XCTAssertEqual(userID, "LASF_Projection")
        // Record ID — 2 bytes: 2112 is the LAS 1.4 OGC Coordinate System WKT record.
        XCTAssertEqual(loadLE(data, at: vlrStart + 18, as: UInt16.self), 2112)

        let recordLength = Int(loadLE(data, at: vlrStart + 20, as: UInt16.self))
        let wktBytes = data.subdata(in: (vlrStart + 54)..<(vlrStart + 54 + recordLength))
        XCTAssertEqual(wktBytes.last, 0, "OGC Coordinate System WKT VLR data must be null-terminated per LAS 1.4 §3.2.2.")
        let wkt = String(decoding: wktBytes.dropLast(), as: UTF8.self)
        XCTAssertTrue(wkt.hasPrefix("LOCAL_CS["), "Default (no control point) export must declare a local, not fabricated geodetic, CRS.")
        XCTAssertTrue(wkt.contains("metre"), "The WKT must declare linear units explicitly.")

        // Offset to Point Data — offset 96 — must land exactly after this VLR.
        let offsetToPointData = Int(loadLE(data, at: 96, as: UInt32.self))
        XCTAssertEqual(offsetToPointData, vlrStart + 54 + recordLength)
    }

    // MARK: - Precision round trip (the plan's literal verification criterion)

    func testPointAt123_456MetersRoundTripsWithSubHalfMillimeterError() throws {
        // ARKit-frame X is untouched by `TopographicAxisConvention`
        // (only Y/Z rotate), so testing X directly avoids needing to
        // reverse that rotation in this test.
        let points = [
            PointCloudExportPoint(position: SIMD3<Float>(0, 0, 0), confidence: 1.0),
            PointCloudExportPoint(position: SIMD3<Float>(123.456, 0, 0), confidence: 1.0),
        ]
        let (url, data) = try writeTempLAS(points)
        defer { try? FileManager.default.removeItem(at: url) }

        let offsetToPointData = Int(loadLE(data, at: 96, as: UInt32.self))
        let xScale = loadLE(data, at: 131, as: Double.self)
        let xOffset = loadLE(data, at: 155, as: Double.self)

        let secondRecordStart = offsetToPointData + Int(LASExporter.pointRecordLength)
        let rawX = loadLE(data, at: secondRecordStart, as: Int32.self)
        let reconstructedX = Double(rawX) * xScale + xOffset

        XCTAssertEqual(reconstructedX, 123.456, accuracy: 0.0005, "A point at 123.456 m must survive the Int32 round trip with under 0.5 mm of error.")
    }

    // MARK: - Return number (fixes the audit's "always 0" finding)

    func testEveryPointIsEncodedAsFirstOfOneReturn() throws {
        let points = [PointCloudExportPoint(position: SIMD3<Float>(1, 1, 1), confidence: 1.0)]
        let (url, data) = try writeTempLAS(points)
        defer { try? FileManager.default.removeItem(at: url) }

        let offsetToPointData = Int(loadLE(data, at: 96, as: UInt32.self))
        let returnByte = data[offsetToPointData + 14]
        let returnNumber = returnByte & 0x0F
        let numberOfReturns = (returnByte >> 4) & 0x0F

        XCTAssertEqual(returnNumber, 1, "return_number == 1 is what a standard first-return filter requires to keep every point.")
        XCTAssertEqual(numberOfReturns, 1)
    }

    // MARK: - Classification mapping

    func testClassificationMapping() {
        XCTAssertEqual(PointCloudMeshClassification.none.lasClassificationCode, 1) // Unclassified
        XCTAssertEqual(PointCloudMeshClassification.floor.lasClassificationCode, 2) // Ground
        XCTAssertEqual(PointCloudMeshClassification.wall.lasClassificationCode, 6) // Building
        XCTAssertEqual(PointCloudMeshClassification.ceiling.lasClassificationCode, 6)
        XCTAssertEqual(PointCloudMeshClassification.window.lasClassificationCode, 6)
        XCTAssertEqual(PointCloudMeshClassification.door.lasClassificationCode, 6)
        XCTAssertGreaterThanOrEqual(PointCloudMeshClassification.table.lasClassificationCode, 64) // User Definable
        XCTAssertGreaterThanOrEqual(PointCloudMeshClassification.seat.lasClassificationCode, 64)
        XCTAssertNotEqual(PointCloudMeshClassification.table.lasClassificationCode, PointCloudMeshClassification.seat.lasClassificationCode)
    }

    func testClassificationByteIsWrittenAtItsOffset() throws {
        let points = [PointCloudExportPoint(position: SIMD3<Float>(0, 0, 0), confidence: 1.0, classification: .floor)]
        let (url, data) = try writeTempLAS(points)
        defer { try? FileManager.default.removeItem(at: url) }

        let offsetToPointData = Int(loadLE(data, at: 96, as: UInt32.self))
        XCTAssertEqual(data[offsetToPointData + 16], 2) // Floor -> Ground
    }

    // MARK: - GPS time / day-of-year (UTC, not local time)

    func testUTCDayOfYearAndYear() {
        // 2024-03-01T12:00:00Z — day 61 of 2024 (31 Jan + 29 Feb 2024 is a leap year + 1).
        let date = Date(timeIntervalSince1970: 1_709_294_400)
        let (dayOfYear, year) = LASExporter.utcDayOfYearAndYear(for: date)
        XCTAssertEqual(year, 2024)
        XCTAssertEqual(dayOfYear, 61)
    }

    func testStandardGPSTimeMatchesTheDocumentedFormula() {
        let gpsEpoch = Date(timeIntervalSince1970: 315_964_800)
        let tenDaysLater = gpsEpoch.addingTimeInterval(10 * 86400)
        let gpsTime = LASExporter.standardGPSTime(for: tenDaysLater)
        XCTAssertEqual(gpsTime, Double(10 * 86400) - 1_000_000_000, accuracy: 0.001)
    }

    // MARK: - Control point (translation-only anchor to a real coordinate)

    func testControlPointShiftsCoordinatesAndWKTReflectsIt() throws {
        // ARKit-frame Z maps to the new Y after `TopographicAxisConvention`
        // (Y_new = -Z_old), so a control point at ARKit Z=0 lands at
        // Z-up-frame Y=0 before any shift is applied.
        let points = [PointCloudExportPoint(position: SIMD3<Float>(0, 0, 0), confidence: 1.0)]
        let controlPoint = ControlPointTransform(
            measuredLocalPosition: SIMD3<Float>(0, 0, 0), // this point's Z-up position
            knownRealCoordinate: SIMD3<Float>(1000, 2000, 50),
            declaredAccuracyMeters: 0.05
        )
        let metadata = PointCloudExportMetadata(capturedAt: Date(), location: nil, pointCount: points.count)
        let baseName = "las_controlpoint_\(UUID().uuidString)"
        let url = try LASExporter.write(points, metadata: metadata, controlPoint: controlPoint, to: FileManager.default.temporaryDirectory, baseName: baseName)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)

        let offsetToPointData = Int(loadLE(data, at: 96, as: UInt32.self))
        let xScale = loadLE(data, at: 131, as: Double.self)
        let xOffset = loadLE(data, at: 155, as: Double.self)
        let rawX = loadLE(data, at: offsetToPointData, as: Int32.self)
        let reconstructedX = Double(rawX) * xScale + xOffset

        XCTAssertEqual(reconstructedX, 1000, accuracy: 0.0005, "The single point coincides with the control point, so it must land exactly on the known real coordinate.")

        // The WKT must reflect that this export is anchored to a control
        // point, not the default arbitrary-origin local frame.
        let recordLength = Int(loadLE(data, at: 375 + 20, as: UInt16.self))
        let wktBytes = data.subdata(in: (375 + 54)..<(375 + 54 + recordLength))
        let wkt = String(decoding: wktBytes.dropLast(), as: UTF8.self)
        XCTAssertTrue(wkt.contains("control point"), "WKT must state the export is anchored to a control point.")
        XCTAssertTrue(wkt.contains("0.050"), "WKT must state the declared accuracy.")
    }

    // MARK: - Empty input

    func testEmptyPointCloudThrows() {
        let metadata = PointCloudExportMetadata(capturedAt: Date(), location: nil, pointCount: 0)
        XCTAssertThrowsError(try LASExporter.write([], metadata: metadata, to: FileManager.default.temporaryDirectory, baseName: "empty")) { error in
            XCTAssertEqual(error as? LASExporter.ExportError, .emptyPointCloud)
        }
    }
}

extension LASExporter.ExportError: Equatable {
    public static func == (lhs: LASExporter.ExportError, rhs: LASExporter.ExportError) -> Bool {
        switch (lhs, rhs) {
        case (.emptyPointCloud, .emptyPointCloud): return true
        default: return false
        }
    }
}
