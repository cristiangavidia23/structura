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

    /// Full-resolution accumulated points, kept for export once the Pro
    /// Scan pass finishes. Not published — read directly by the export
    /// coordinator when the user requests a file.
    private(set) var accumulatedPositions: [SIMD3<Float>] = []
    private(set) var accumulatedConfidences: [Float] = []

    private let downsampleStride = 4 // keep memory bounded across a long pass

    func reset() {
        pointCount = 0
        lastUpdate = nil
        accumulatedPositions.removeAll(keepingCapacity: false)
        accumulatedConfidences.removeAll(keepingCapacity: false)
    }

    func ingest(_ frame: PointCloudFrame) {
        var index = 0
        while index < frame.positions.count {
            accumulatedPositions.append(frame.positions[index])
            accumulatedConfidences.append(frame.confidences[index])
            index += downsampleStride
        }
        pointCount = accumulatedPositions.count
        lastUpdate = Date()
    }
}
