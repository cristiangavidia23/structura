import Foundation

/// Lock-protected double/triple buffer handing completed `PointCloudFrame`s
/// from the ARKit capture thread to the Metal render thread without either
/// side blocking the other. The writer always overwrites the oldest slot;
/// the reader always reads the newest completed slot.
final class PointCloudRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: PointCloudFrame = .empty

    func write(_ frame: PointCloudFrame) {
        lock.lock()
        latest = frame
        lock.unlock()
    }

    func readLatest() -> PointCloudFrame {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
}
