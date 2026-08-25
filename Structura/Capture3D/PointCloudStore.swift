import Foundation

/// UI-facing store for the Pro Scan point cloud. Publishes only lightweight
/// metrics for SwiftUI/HUD binding — the actual point buffers live in the
/// ring buffer feeding the Metal renderer, never bridged through
/// `@Published` (would be a serious Combine-diffing/perf mistake at this
/// scale).
@MainActor
final class PointCloudStore: ObservableObject {
    @Published private(set) var pointCount: Int = 0
    @Published private(set) var lastUpdate: Date?

    /// Deduplicated accumulated points, kept for export once the Pro Scan
    /// pass finishes. Not published — read directly by the export
    /// coordinator when the user requests a file.
    private(set) var accumulatedPositions: [SIMD3<Float>] = []
    private(set) var accumulatedConfidences: [Float] = []

    /// The same wall gets swept by the depth camera dozens of times as the
    /// user pans around it; without deduplication, those near-duplicate
    /// samples pile up into a smeared, noisy blob instead of a clean
    /// surface. Each frame's points are snapped onto a coarse 3D grid, and
    /// only the highest-confidence sample per cell is kept.
    private let voxelSizeMeters: Float = 0.02
    private var voxelIndex: [Int64: Int] = [:]

    func reset() {
        pointCount = 0
        lastUpdate = nil
        accumulatedPositions.removeAll(keepingCapacity: false)
        accumulatedConfidences.removeAll(keepingCapacity: false)
        voxelIndex.removeAll(keepingCapacity: false)
    }

    func ingest(_ frame: PointCloudFrame) {
        for i in 0..<frame.positions.count {
            let position = frame.positions[i]
            let confidence = frame.confidences[i]
            let key = voxelKey(for: position)

            if let existingIndex = voxelIndex[key] {
                if confidence > accumulatedConfidences[existingIndex] {
                    accumulatedPositions[existingIndex] = position
                    accumulatedConfidences[existingIndex] = confidence
                }
            } else {
                voxelIndex[key] = accumulatedPositions.count
                accumulatedPositions.append(position)
                accumulatedConfidences.append(confidence)
            }
        }
        pointCount = accumulatedPositions.count
        lastUpdate = Date()
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
