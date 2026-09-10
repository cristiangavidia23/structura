import ARKit
import Foundation

/// Persists an `ARSession`'s `ARWorldMap` between Pro Scan passes, keyed by
/// scan name — Fase 3 of the architecture audit, the part of finding E4 that
/// was deliberately left unimplemented pending a product decision (see
/// `claude/f1-progreso.md`, section "F3 (parcial)"). Cristian's call once
/// asked: key continuity by scan *name*, not a dedicated project/phase field
/// (`ScanRecord` has none today) — if the user names two Pro Scan passes the
/// same thing, the second is offered the first's world map.
///
/// Deliberately narrower than the audit's original ask: this only lets a
/// later Pro Scan pass over the *same named scan* continue in the same
/// coordinate frame. It does not, and cannot with a public API, share a
/// world map with RoomPlan — `RoomCaptureSession` manages its own `ARSession`
/// with no documented way to extract or inject one.
enum WorldMapStore {
    /// Sanitized so a scan name can't escape the world-maps directory
    /// (path traversal via "../") or collide with the filesystem's own
    /// reserved characters — the same concern `ScanStore` already handles
    /// for its own file names, applied here for the same reason.
    private static func sanitizedFileName(forScanName name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = CharacterSet.alphanumerics
        let sanitized = String(trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return sanitized.isEmpty ? "_" : sanitized
    }

    private static var directory: URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProScanWorldMaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func url(forScanName name: String) -> URL {
        directory.appendingPathComponent(sanitizedFileName(forScanName: name)).appendingPathExtension("worldmap")
    }

    /// `true` if a Pro Scan pass previously saved a world map under this
    /// scan name — cheap enough (a file-existence check) to call from the
    /// main actor right before offering the user "continue this scan?".
    static func hasSavedWorldMap(forScanName name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(forScanName: name).path)
    }

    /// Loads the world map saved for this scan name, if any. `ARWorldMap`
    /// conforms to `NSSecureCoding`, not plain `Codable` — this is Apple's
    /// own documented persistence pattern for it
    /// (`NSKeyedUnarchiver`/`NSKeyedArchiver`), the same one
    /// `RelocalizationConfirmation`'s doc comment points to.
    static func load(forScanName name: String) -> ARWorldMap? {
        guard let data = try? Data(contentsOf: url(forScanName: name)) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
    }

    /// Overwrites any previously-saved world map for this scan name —
    /// each Pro Scan pass over the same name replaces the continuity point
    /// with its own, more recent, end state.
    static func save(_ worldMap: ARWorldMap, forScanName name: String) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true) else { return }
        try? data.write(to: url(forScanName: name), options: .atomic)
    }
}
