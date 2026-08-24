import Foundation
import QuartzCore
import ARKit

/// Live capture metrics for the HUD: FPS via CADisplayLink (frame counting
/// only — cheap enough to run on the main run loop), RAM sampled off-thread,
/// and point count / tracking state pushed in by the Pro Scan capture session
/// rather than polled.
@MainActor
final class PerformanceMonitor: ObservableObject {
    @Published private(set) var fps: Double = 0
    @Published private(set) var memoryUsedMB: Double = 0
    @Published private(set) var pointCount: Int = 0
    @Published private(set) var trackingState: ARCamera.TrackingState = .normal

    private var displayLink: CADisplayLink?
    private var lastFPSSampleTime: CFTimeInterval = 0
    private var frameCount = 0
    private var memoryTask: Task<Void, Never>?

    func start() {
        stop()

        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastFPSSampleTime = CACurrentMediaTime()
        frameCount = 0

        memoryTask = Task { [weak self] in
            while !Task.isCancelled {
                let usedMB = Self.currentMemoryUsageMB()
                await MainActor.run { self?.memoryUsedMB = usedMB }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        memoryTask?.cancel()
        memoryTask = nil
        fps = 0
    }

    func reportPointCount(_ count: Int) {
        pointCount = count
    }

    func reportTrackingState(_ state: ARCamera.TrackingState) {
        trackingState = state
    }

    @objc private func tick(_ link: CADisplayLink) {
        frameCount += 1
        let elapsed = link.timestamp - lastFPSSampleTime
        guard elapsed >= 0.5 else { return }
        fps = Double(frameCount) / elapsed
        frameCount = 0
        lastFPSSampleTime = link.timestamp
    }

    /// Resident memory footprint of this process, in megabytes.
    nonisolated private static func currentMemoryUsageMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576.0
    }
}
