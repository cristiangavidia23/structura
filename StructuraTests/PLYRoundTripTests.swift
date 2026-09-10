import Foundation
import simd
import XCTest

/// Ida y vuelta PLY: write N points, read them back, and compare — per the
/// Fase 4 verification plan. `PLYExporter`/`PLYPointCloudReader` are a
/// matched pair (see both files' doc comments), so this is the test that
/// actually proves they still agree with each other after a schema change.
final class PLYRoundTripTests: XCTestCase {
    func testWriteThenReadRoundTripsAllFields() throws {
        let classifications = PointCloudMeshClassification.allCases
        var points: [PointCloudExportPoint] = []
        for i in 0..<50 {
            let iFloat = Float(i)
            let position = SIMD3<Float>(iFloat * 0.1, iFloat * -0.2, iFloat * 0.05)
            let confidence: Float = iFloat / 50.0
            let colorR: Float = Float(i % 256) / 255
            let colorG: Float = Float((i * 3) % 256) / 255
            let colorB: Float = Float((i * 7) % 256) / 255
            let color = SIMD3<Float>(colorR, colorG, colorB)
            let rawNormal = SIMD3<Float>(1, iFloat, -iFloat * 0.5)
            let normal = simd_normalize(rawNormal)
            let classification = classifications[i % classifications.count]
            points.append(PointCloudExportPoint(
                position: position,
                confidence: confidence,
                color: color,
                normal: normal,
                classification: classification
            ))
        }
        let metadata = PointCloudExportMetadata(capturedAt: Date(), location: nil, pointCount: points.count)
        let baseName = "ply_roundtrip_\(UUID().uuidString)"
        let url = try PLYExporter.write(points, metadata: metadata, to: FileManager.default.temporaryDirectory, baseName: baseName)
        defer { try? FileManager.default.removeItem(at: url) }

        let readBack = try XCTUnwrap(PLYPointCloudReader.read(from: url))
        XCTAssertEqual(readBack.count, points.count)

        for (original, roundTripped) in zip(points, readBack) {
            // Position/confidence/normal are stored as full Float32 with no
            // intervening computation — must survive bit-exact.
            XCTAssertEqual(roundTripped.position, original.position)
            XCTAssertEqual(roundTripped.confidence, original.confidence)
            XCTAssertEqual(roundTripped.normal, original.normal)
            XCTAssertEqual(roundTripped.classification, original.classification)

            // Color is quantized to 8 bits per channel on write — compare
            // against that same quantization, not the pre-quantization
            // float (an 8-bit round trip is a documented lossy step here,
            // not a bug).
            let expectedR = Float(UInt8(min(max(original.color.x * 255, 0), 255))) / 255
            let expectedG = Float(UInt8(min(max(original.color.y * 255, 0), 255))) / 255
            let expectedB = Float(UInt8(min(max(original.color.z * 255, 0), 255))) / 255
            XCTAssertEqual(roundTripped.color.x, expectedR, accuracy: 0.0001)
            XCTAssertEqual(roundTripped.color.y, expectedG, accuracy: 0.0001)
            XCTAssertEqual(roundTripped.color.z, expectedB, accuracy: 0.0001)
        }
    }

    /// A file built by hand in the Fase 0-2 schema (x,y,z,confidence + RGB,
    /// no normal/classification) — `PLYExporter` always writes the current
    /// schema now, so this specifically exercises the reader's
    /// backward-compatibility detection against an *older* real shape.
    func testReaderHandlesPreFase4FilesWithoutNormalOrClassification() throws {
        let header = """
        ply
        format binary_little_endian 1.0
        element vertex 1
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
        withUnsafeBytes(of: Float(1.5)) { data.append(contentsOf: $0) } // x
        withUnsafeBytes(of: Float(2.5)) { data.append(contentsOf: $0) } // y
        withUnsafeBytes(of: Float(3.5)) { data.append(contentsOf: $0) } // z
        withUnsafeBytes(of: Float(0.75)) { data.append(contentsOf: $0) } // confidence
        data.append(contentsOf: [10, 20, 30]) // r, g, b

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ply_legacy_\(UUID().uuidString).ply")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let points = try XCTUnwrap(PLYPointCloudReader.read(from: url))
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].position, SIMD3<Float>(1.5, 2.5, 3.5))
        XCTAssertEqual(points[0].confidence, 0.75, accuracy: 0.0001)
        XCTAssertEqual(points[0].classification, .none, "A pre-Fase-4 file has no classification data; must default rather than misread trailing bytes.")
        XCTAssertEqual(points[0].normal, SIMD3<Float>(0, 1, 0), "A pre-Fase-4 file has no normal data; must default rather than misread trailing bytes.")
    }

    func testEmptyPointCloudThrows() {
        let metadata = PointCloudExportMetadata(capturedAt: Date(), location: nil, pointCount: 0)
        XCTAssertThrowsError(try PLYExporter.write([], metadata: metadata, to: FileManager.default.temporaryDirectory, baseName: "empty"))
    }

    // MARK: - Streamed writing (Fase 1: audit finding C7)

    /// The exact shape of `PLYExporter`'s real caller: autosave writes the
    /// same `baseName` repeatedly, every few seconds, as the scan grows.
    /// `write` must fully replace the previous file's content each time —
    /// not append to it, and not leave stray bytes from a longer previous
    /// version behind a shorter new one.
    func testRepeatedWritesToTheSameNameFullyReplaceThePreviousContent() throws {
        let baseName = "ply_autosave_\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory

        func point(_ x: Float) -> PointCloudExportPoint {
            PointCloudExportPoint(position: SIMD3(x, 0, 0), confidence: 1, color: SIMD3(1, 1, 1), normal: SIMD3(0, 1, 0), classification: .wall)
        }

        let metadata = PointCloudExportMetadata(capturedAt: Date(), location: nil, pointCount: 0)

        // First "tick": a larger scan than the second, so a naive
        // overwrite that failed to truncate would leave the second read
        // seeing leftover vertices past its own declared `element vertex`
        // count — or, worse, a reader that trusts the header's count would
        // silently miss that the trailing bytes are stale.
        let firstTick = (0..<500).map { point(Float($0)) }
        let firstURL = try PLYExporter.write(firstTick, metadata: metadata, to: directory, baseName: baseName)
        defer { try? FileManager.default.removeItem(at: firstURL) }
        let firstFileSize = try FileManager.default.attributesOfItem(atPath: firstURL.path)[.size] as? Int

        let secondTick = (0..<10).map { point(Float($0) * 2) }
        let secondURL = try PLYExporter.write(secondTick, metadata: metadata, to: directory, baseName: baseName)
        let secondFileSize = try FileManager.default.attributesOfItem(atPath: secondURL.path)[.size] as? Int

        XCTAssertEqual(firstURL, secondURL, "Autosave writes the same filename every tick.")
        XCTAssertNotEqual(firstFileSize, secondFileSize, "A shorter second write must actually shrink the file, not leave trailing bytes from the first.")

        let readBack = try XCTUnwrap(PLYPointCloudReader.read(from: secondURL))
        XCTAssertEqual(readBack.count, secondTick.count)
        XCTAssertEqual(readBack.map(\.position.x), secondTick.map(\.position.x))
    }

    /// Exercises multiple internal batch flushes (see `PLYExporter
    /// .pointsPerBatch`), not just a single-batch write, so a boundary bug
    /// in the batching itself (a dropped or duplicated point at a flush
    /// edge) would show up as a count or ordering mismatch.
    func testWriteSpanningMultipleBatchesRoundTrips() throws {
        let count = 20_000 // several multiples of the internal batch size
        var points: [PointCloudExportPoint] = []
        points.reserveCapacity(count)
        for i in 0..<count {
            points.append(PointCloudExportPoint(
                position: SIMD3(Float(i) * 0.001, 0, 0),
                confidence: 0.5,
                color: SIMD3(0.2, 0.4, 0.6),
                normal: SIMD3(0, 1, 0),
                classification: .floor
            ))
        }

        let metadata = PointCloudExportMetadata(capturedAt: Date(), location: nil, pointCount: points.count)
        let baseName = "ply_multibatch_\(UUID().uuidString)"
        let url = try PLYExporter.write(points, metadata: metadata, to: FileManager.default.temporaryDirectory, baseName: baseName)
        defer { try? FileManager.default.removeItem(at: url) }

        let readBack = try XCTUnwrap(PLYPointCloudReader.read(from: url))
        XCTAssertEqual(readBack.count, count)
        XCTAssertEqual(readBack.first?.position.x, 0)
        let lastX = try XCTUnwrap(readBack.last?.position.x)
        XCTAssertEqual(lastX, Float(count - 1) * 0.001, accuracy: 0.0001)
    }

    /// `write` must not leave its `.tmp` staging file behind, whether it
    /// succeeds (moved/replaced into the final name) or the temp file is
    /// otherwise orphaned.
    func testWriteLeavesNoTemporaryFileBehind() throws {
        let metadata = PointCloudExportMetadata(capturedAt: Date(), location: nil, pointCount: 1)
        let baseName = "ply_notemp_\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
        let url = try PLYExporter.write([point(1)], metadata: metadata, to: directory, baseName: baseName)
        defer { try? FileManager.default.removeItem(at: url) }

        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let strayTempFiles = siblings.filter { $0.hasPrefix(baseName) && $0 != url.lastPathComponent }
        XCTAssertTrue(strayTempFiles.isEmpty, "No .tmp staging file should remain: \(strayTempFiles)")
    }

    private func point(_ x: Float) -> PointCloudExportPoint {
        PointCloudExportPoint(position: SIMD3(x, 0, 0), confidence: 1, color: SIMD3(1, 1, 1), normal: SIMD3(0, 1, 0), classification: .wall)
    }
}
