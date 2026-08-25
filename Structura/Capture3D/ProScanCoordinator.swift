import ARKit
import Combine
import UIKit
import Metal

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
    let metalRenderer: MetalPointCloudRenderer?

    private let arSession = ARPointCloudSession()
    var session: ARSession { arSession.session }
    private let hapticEngine = HapticEngineManager()
    private(set) lazy var haptics = HapticFeedbackAdapter(engineManager: hapticEngine)

    private var wasTrackingDegraded = false

    static var isSupported: Bool { ARPointCloudSession.isSupported }

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            metalRenderer = MetalPointCloudRenderer(device: device, ringBuffer: ringBuffer)
        } else {
            metalRenderer = nil
        }

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

    /// The scan to actually export/visualize: ARKit's fused mesh
    /// reconstruction rather than the raw per-frame depth accumulated in
    /// `pointCloudStore` (that one only drives the live heatmap overlay).
    func currentMeshPoints() -> [PointCloudExportPoint] {
        arSession.currentMeshPoints()
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
