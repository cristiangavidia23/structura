import Foundation

/// UI-facing store for the Pro Scan point cloud. Publishes only lightweight
/// metrics for SwiftUI/HUD binding — the actual point buffers live in the
/// ring buffer feeding the Metal renderer, never bridged through
/// `@Published` (would be a serious Combine-diffing/perf mistake at this
/// scale).
///
/// # Not `@MainActor` (Fase 1 of the architecture audit, finding C5)
///
/// `ingest(_:)` used to be reachable only via `Task { @MainActor in ... }`
/// from `ProScanCoordinator`, which forced every throttled depth frame's
/// dedup/accumulation loop (~1,900 points at `ProScanConfig.depthSampleHz`
/// — a dictionary lookup and up to three array mutations per point) onto
/// the main actor, even though none of that work reads or writes any UI
/// state. `ingest` now runs directly on whatever queue calls it — in
/// practice, `ARPointCloudSession`'s `delegateQueue` — with its mutable
/// state protected by its own lock instead of actor isolation, the same
/// pattern `ARPointCloudSession`/`ConfidenceGrid` already use for the same
/// reason. Only the two properties actually meant for UI binding
/// (`pointCount`, `lastUpdate`) are still marshaled onto the main actor —
/// and only at most twice a second (`publishIntervalSeconds`), not once
/// per ingested frame, since nothing about their value changes fast enough
/// to need finer granularity than that.
///
/// `@unchecked Sendable` for the same reason as `ARPointCloudSession`:
/// every mutable stored property below is only ever touched under `lock`.
final class PointCloudStore: ObservableObject, @unchecked Sendable {
    @Published private(set) var pointCount: Int = 0
    @Published private(set) var lastUpdate: Date?

    private let lock = NSLock()

    /// Deduplicated accumulated points, kept for export once the Pro Scan
    /// pass finishes — see `accumulatedSnapshot()`. Private (not
    /// `private(set)`): with `ingest` no longer confined to the main actor,
    /// an external reader touching these directly would bypass `lock` and
    /// race a concurrent `ingest`/`reset` call.
    private var accumulatedPositions: [SIMD3<Float>] = []
    private var accumulatedConfidences: [Float] = []
    private var accumulatedColors: [SIMD3<Float>] = []

    /// The same wall gets swept by the depth camera dozens of times as the
    /// user pans around it; without deduplication, those near-duplicate
    /// samples pile up into a smeared, noisy blob instead of a clean
    /// surface. Each frame's points are snapped onto a coarse 3D grid, and
    /// only the highest-confidence sample per cell is kept.
    private let voxelSizeMeters: Float = 0.02
    private var voxelIndex: [Int64: Int] = [:]

    /// Throttle state for the `@Published` publish in `ingest` — see that
    /// method and `publishIntervalSeconds`. Guarded by `lock` alongside the
    /// accumulation state, even though it's logically independent, so
    /// `ingest` only needs to take the lock once per call.
    private var lastPublishedAt: Date = .distantPast
    private static let publishIntervalSeconds: TimeInterval = 0.5 // 2 Hz

    func reset() {
        lock.lock()
        accumulatedPositions.removeAll(keepingCapacity: false)
        accumulatedConfidences.removeAll(keepingCapacity: false)
        accumulatedColors.removeAll(keepingCapacity: false)
        voxelIndex.removeAll(keepingCapacity: false)
        lastPublishedAt = .distantPast
        lock.unlock()

        // `reset()` is called once per scan start (`ProScanCoordinator
        // .start()`, on the main actor), not per frame — publishing
        // unconditionally here, rather than going through the same
        // throttle `ingest` uses, is what makes a fresh scan's HUD state
        // (if anything ever binds to it — see this type's doc comment)
        // clear immediately instead of waiting up to
        // `publishIntervalSeconds` to reflect the reset.
        pointCount = 0
        lastUpdate = nil
    }

    /// Folds one throttled raw-depth-pipeline frame's points into the
    /// running voxel-deduplicated accumulation. Safe to call from any
    /// thread; see this type's doc comment for why that's true and why it
    /// matters.
    func ingest(_ frame: PointCloudFrame) {
        let publishedCount: Int?
        let publishedAt: Date?

        lock.lock()
        for i in 0..<frame.positions.count {
            let position = frame.positions[i]
            let confidence = frame.confidences[i]
            let color = frame.colors.indices.contains(i) ? frame.colors[i] : SIMD3<Float>(0.5, 0.5, 0.5)
            let key = voxelKey(for: position)

            if let existingIndex = voxelIndex[key] {
                if confidence > accumulatedConfidences[existingIndex] {
                    accumulatedPositions[existingIndex] = position
                    accumulatedConfidences[existingIndex] = confidence
                    accumulatedColors[existingIndex] = color
                }
            } else {
                voxelIndex[key] = accumulatedPositions.count
                accumulatedPositions.append(position)
                accumulatedConfidences.append(confidence)
                accumulatedColors.append(color)
            }
        }

        let now = Date()
        if now.timeIntervalSince(lastPublishedAt) >= Self.publishIntervalSeconds {
            lastPublishedAt = now
            publishedCount = accumulatedPositions.count
            publishedAt = now
        } else {
            publishedCount = nil
            publishedAt = nil
        }
        lock.unlock()

        // The `@Published` writes must land on the main actor (SwiftUI/
        // Combine's contract for anything a View might bind to), but only
        // when the throttle above actually allowed a publish this call —
        // most calls, at `ProScanConfig.depthSampleHz`, will skip this
        // entirely.
        guard let publishedCount, let publishedAt else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pointCount = publishedCount
            self.lastUpdate = publishedAt
        }
    }

    /// A snapshot of the deduplicated accumulated points, for the export
    /// coordinator this type's own doc comment says they're kept for.
    /// Copies all three arrays under one lock acquisition rather than
    /// three, so a concurrent `ingest` can't be interleaved between them
    /// and hand back positions/confidences/colors that don't correspond to
    /// the same accumulation state.
    func accumulatedSnapshot() -> (positions: [SIMD3<Float>], confidences: [Float], colors: [SIMD3<Float>]) {
        lock.lock()
        defer { lock.unlock() }
        return (accumulatedPositions, accumulatedConfidences, accumulatedColors)
    }

    private func voxelKey(for position: SIMD3<Float>) -> Int64 {
        // Packs three 20-bit signed cell coordinates into one Int64 —
        // comfortably covers any room-scale scan (±5,000 cells ≈ ±100m at
        // this voxel size) without allocating a struct key per point.
        let x = Int64((position.x / voxelSizeMeters).rounded()) & 0x1FFFFF
        let y = Int64((position.y / voxelSizeMeters).rounded()) & 0x1FFFFF
        let z = Int64((position.z / voxelSizeMeters).rounded()) & 0x1FFFFF
        return (x << 42) | (y << 21) | z
    }
}
