import Foundation
import QuartzCore
import ARKit

/// Live capture metrics for the HUD: FPS via CADisplayLink (frame counting
/// only — cheap enough to run on the main run loop), RAM sampled off-thread,
/// and point count / tracking state pushed in by the Pro Scan capture session
/// rather than polled.
///
/// # Fase 0 additions (architecture audit: "sin línea base todo lo demás es
/// opinión")
///
/// `fps` above is screen refresh rate (`CADisplayLink`), not ARKit's own
/// frame delivery rate — a real distinction, not a naming nitpick: a device
/// can hold 60 fps on screen while ARKit's actual delivery has stalled
/// behind a backed-up delegate queue (finding E7). `arkitFPS`/
/// `delegateLatencyMs`/`maxDelegateLatencyMs` are the real signal for that,
/// computed by `DelegateFrameMetrics` from every `didUpdate frame:` call and
/// pushed in here via `reportARKitFrame(_:)` — already throttled to at most
/// once a second at the source (`ARPointCloudSession`), so receiving it here
/// is exactly as cheap as `reportPointCount`/`reportTrackingState` above,
/// not a new per-frame main-actor cost.
///
/// `thermalState` and `peakMemoryUsedMB` are the other two Fase 0 asks:
/// registering thermal state and memory so a real-device profiling session
/// has both numbers alongside FPS/latency, without needing a separate
/// Instruments capture just to see whether a run got thermally throttled or
/// its memory footprint kept climbing.
@MainActor
final class PerformanceMonitor: ObservableObject {
    @Published private(set) var fps: Double = 0
    @Published private(set) var memoryUsedMB: Double = 0
    @Published private(set) var peakMemoryUsedMB: Double = 0
    @Published private(set) var pointCount: Int = 0
    @Published private(set) var trackingState: ARCamera.TrackingState = .normal
    @Published private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var arkitFPS: Double = 0
    @Published private(set) var delegateLatencyMs: Double = 0
    @Published private(set) var maxDelegateLatencyMs: Double = 0

    private var displayLink: CADisplayLink?
    private var lastFPSSampleTime: CFTimeInterval = 0
    private var frameCount = 0
    private var memoryTask: Task<Void, Never>?
    private var thermalStateObserver: NSObjectProtocol?

    func start() {
        stop()

        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastFPSSampleTime = CACurrentMediaTime()
        frameCount = 0
        peakMemoryUsedMB = 0
        arkitFPS = 0
        delegateLatencyMs = 0
        maxDelegateLatencyMs = 0

        memoryTask = Task { [weak self] in
            while !Task.isCancelled {
                let usedMB = Self.currentMemoryUsageMB()
                await MainActor.run {
                    self?.memoryUsedMB = usedMB
                    if let self, usedMB > self.peakMemoryUsedMB {
                        self.peakMemoryUsedMB = usedMB
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        thermalState = ProcessInfo.processInfo.thermalState
        thermalStateObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.thermalState = ProcessInfo.processInfo.thermalState
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        memoryTask?.cancel()
        memoryTask = nil
        if let thermalStateObserver {
            NotificationCenter.default.removeObserver(thermalStateObserver)
        }
        thermalStateObserver = nil
        fps = 0
    }

    func reportPointCount(_ count: Int) {
        pointCount = count
    }

    func reportTrackingState(_ state: ARCamera.TrackingState) {
        trackingState = state
    }

    /// Receives a throttled (at most 1 Hz, already enforced by the caller)
    /// ARKit delivery-rate/delegate-latency summary — see this type's doc
    /// comment and `DelegateFrameMetrics`.
    func reportARKitFrame(_ snapshot: DelegateFrameMetrics.Snapshot) {
        arkitFPS = snapshot.arkitFPS
        delegateLatencyMs = snapshot.meanDelegateLatencyMs
        maxDelegateLatencyMs = snapshot.maxDelegateLatencyMs
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
