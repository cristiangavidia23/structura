import Foundation
import UIKit
import RoomPlan
import QuickLookThumbnailing

@MainActor
final class ScanStore: ObservableObject {
    @Published private(set) var scans: [ScanRecord] = []

    private let indexURL: URL
    let scansDirectory: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        scansDirectory = documents.appendingPathComponent("Scans", isDirectory: true)
        indexURL = scansDirectory.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: scansDirectory, withIntermediateDirectories: true)
        load()
    }

    func usdzURL(for record: ScanRecord) -> URL {
        scansDirectory.appendingPathComponent(record.usdzFileName)
    }

    func thumbnailURL(for record: ScanRecord) -> URL? {
        guard let name = record.thumbnailFileName else { return nil }
        return scansDirectory.appendingPathComponent(name)
    }

    func capturedRoom(for record: ScanRecord) -> CapturedRoom? {
        let url = scansDirectory.appendingPathComponent(record.roomFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CapturedRoom.self, from: data)
    }

    func delete(_ record: ScanRecord) {
        scans.removeAll { $0.id == record.id }
        try? FileManager.default.removeItem(at: usdzURL(for: record))
        try? FileManager.default.removeItem(at: scansDirectory.appendingPathComponent(record.roomFileName))
        if let thumbnailURL = thumbnailURL(for: record) {
            try? FileManager.default.removeItem(at: thumbnailURL)
        }
        persist()
    }

    /// Returns `nil` if the USDZ export itself fails — the one file every other
    /// screen depends on (dollhouse projection, share sheet). A room-data or
    /// thumbnail failure is tolerated: `capturedRoom(for:)` and the card's
    /// fallback icon already degrade gracefully without them.
    @discardableResult
    func save(capturedRoom: CapturedRoom, name: String) async -> ScanRecord? {
        let id = UUID()
        let usdzFileName = "\(id.uuidString).usdz"
        let usdzURL = scansDirectory.appendingPathComponent(usdzFileName)

        do {
            try capturedRoom.export(to: usdzURL, exportOptions: .parametric)
        } catch {
            return nil
        }

        let roomFileName = "\(id.uuidString)_room.json"
        if let roomData = try? JSONEncoder().encode(capturedRoom) {
            try? roomData.write(to: scansDirectory.appendingPathComponent(roomFileName), options: .atomic)
        }

        let thumbnailFileName = "\(id.uuidString)_thumb.png"
        let thumbnailURL = scansDirectory.appendingPathComponent(thumbnailFileName)
        let thumbnailSaved = await Self.generateThumbnail(from: usdzURL, savingTo: thumbnailURL)

        let record = ScanRecord(
            id: id,
            name: name,
            createdAt: Date(),
            usdzFileName: usdzFileName,
            thumbnailFileName: thumbnailSaved ? thumbnailFileName : nil,
            roomFileName: roomFileName
        )
        scans.insert(record, at: 0)
        persist()
        return record
    }

    private static func generateThumbnail(from usdzURL: URL, savingTo destination: URL) async -> Bool {
        // Fixed scale rather than the screen's: the thumbnail is written to disk and
        // reused across devices, so it should not depend on the capturing device.
        let request = QLThumbnailGenerator.Request(
            fileAt: usdzURL,
            size: CGSize(width: 400, height: 400),
            scale: 2,
            representationTypes: .thumbnail
        )
        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            guard let data = representation.uiImage.pngData() else { return false }
            try data.write(to: destination, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([ScanRecord].self, from: data) else { return }
        scans = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(scans) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
