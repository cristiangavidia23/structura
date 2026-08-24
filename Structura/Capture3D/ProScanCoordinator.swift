import ARKit
import Combine
import UIKit

/// Orchestrates the Pro Scan second pass: the raw ARKit session, its
/// derived point cloud store, performance metrics, the Metal ring buffer,
/// and capture-flow haptics. Owned by `CaptureView` alongside (never
/// concurrently with) the existing RoomPlan `CaptureCoordinator`.
@MainActor
final class ProScanCoordinator: ObservableObject {
    @Published private(set) var isRunning = false
    @Published var isHeatmapVisible = true
    @Published var failureMessage: String?

    let performanceMonitor = PerformanceMonitor()
    let pointCloudStore = PointCloudStore()
    let ringBuffer = PointCloudRingBuffer()

    private let arSession = ARPointCloudSession()
    private let hapticEngine = HapticEngineManager()
    private(set) lazy var haptics = HapticFeedbackAdapter(engineManager: hapticEngine)

    private var wasTrackingDegraded = false

    static var isSupported: Bool { ARPointCloudSession.isSupported }

    init() {
        arSession.onFrame = { [weak self] frame in
            guard let self else { return }
            self.ringBuffer.write(frame)
            Task { @MainActor in
                self.pointCloudStore.ingest(frame)
                self.performanceMonitor.reportPointCount(self.pointCloudStore.pointCount)
                self.haptics.samplingTick()
            }
        }
        arSession.onTrackingState = { [weak self] state in
            Task { @MainActor in
                self?.handleTrackingState(state)
            }
        }
        arSession.onFailure = { [weak self] message in
            Task { @MainActor in
                self?.failureMessage = message
            }
        }
    }

    func start(viewportSize: CGSize, interfaceOrientation: UIInterfaceOrientation) {
        guard Self.isSupported, !isRunning else { return }
        pointCloudStore.reset()
        performanceMonitor.start()
        hapticEngine.start()
        arSession.start(viewportSize: viewportSize, interfaceOrientation: interfaceOrientation)
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        arSession.stop()
        performanceMonitor.stop()
        hapticEngine.stop()
        isRunning = false
    }

    func confirmMeshClosed() {
        haptics.meshClosed()
    }

    private func handleTrackingState(_ state: ARCamera.TrackingState) {
        performanceMonitor.reportTrackingState(state)

        let isDegraded: Bool
        switch state {
        case .normal: isDegraded = false
        case .limited, .notAvailable: isDegraded = true
        }

        if isDegraded && !wasTrackingDegraded {
            haptics.trackingLostProgressive()
        }
        wasTrackingDegraded = isDegraded
    }
}
