import simd

/// Per-voxel confidence and coverage signal, fed by the throttled raw-depth
/// pipeline (`ARPointCloudSession.processFrame`, gated to
/// `ProScanConfig.depthSampleHz`) and consulted by the fused-mesh pipeline
/// (`processMeshAnchor`) so exported mesh points get a real per-point
/// confidence instead of the placeholder `1.0` the Pro Scan audit flagged
/// as a critical finding.
///
/// # Locked, not queue-confined (Fase 1 of the architecture audit)
///
/// This type used to rely entirely on both call sites running on the same
/// serial queue, with no lock of its own. That stopped being true once
/// mesh-anchor processing moved to its own `meshProcessingQueue`, separate
/// from the queue `processFrame` runs on (see `ARPointCloudSession
/// .meshProcessingQueue`'s doc comment, audit finding C4): `record` and
/// `confidence(at:)`/`reset()` are now genuinely called from two different
/// queues, concurrently. An `NSLock` around every access — matching the
/// pattern `ARPointCloudSession.meshLock` already uses — is what keeps that
/// safe, at the cost of one lock/unlock per call. That cost is small next
/// to what it protects: a single-cell dictionary read or a scalar-sum
/// update, not a loop.
///
/// Pure Swift/simd, no ARKit dependency — like `ProScanConfig` and
/// `CameraUnprojection`, so it compiles into the host-less `StructuraTests`
/// logic-test target and has synthetic-data tests for its voxel hashing.
final class ConfidenceGrid {
    private struct Cell {
        var confidenceSum: Float = 0
        var observationCount: Int = 0

        var averageConfidence: Float {
            observationCount > 0 ? confidenceSum / Float(observationCount) : 0
        }
    }

    private let lock = NSLock()
    private var cells: [Int64: Cell] = [:]

    func reset() {
        lock.lock()
        cells.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    /// Folds one observed sample — a real per-frame depth reading's
    /// world-space position and already-normalized confidence — into its
    /// voxel's running average.
    func record(position: SIMD3<Float>, confidence: Float) {
        let key = Self.voxelKey(for: position)
        lock.lock()
        var cell = cells[key] ?? Cell()
        cell.confidenceSum += confidence
        cell.observationCount += 1
        cells[key] = cell
        lock.unlock()
    }

    /// The averaged confidence at the voxel containing `position`, or `nil`
    /// if the depth pipeline has never observed that voxel.
    func confidence(at position: SIMD3<Float>) -> Float? {
        let key = Self.voxelKey(for: position)
        lock.lock()
        defer { lock.unlock() }
        guard let cell = cells[key], cell.observationCount > 0 else { return nil }
        return cell.averageConfidence
    }

    /// Number of distinct voxels observed so far — a coverage signal.
    var observedVoxelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cells.count
    }

    /// Packs a world-space position into a voxel-grid cell key, at
    /// `ProScanConfig.voxelSizeMeters` resolution. Matches the packing
    /// scheme already shipping in `PointCloudStore.voxelKey(for:)`: three
    /// 20-bit signed cell coordinates packed into one `Int64` — comfortably
    /// covers any room-scale scan (±5,000 cells ≈ ±100 m at this voxel
    /// size) without allocating a struct key per point.
    static func voxelKey(for position: SIMD3<Float>) -> Int64 {
        let x = Int64((position.x / ProScanConfig.voxelSizeMeters).rounded()) & 0x1FFFFF
        let y = Int64((position.y / ProScanConfig.voxelSizeMeters).rounded()) & 0x1FFFFF
        let z = Int64((position.z / ProScanConfig.voxelSizeMeters).rounded()) & 0x1FFFFF
        return (x << 42) | (y << 21) | z
    }
}
