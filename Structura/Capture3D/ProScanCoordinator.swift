import ARKit
import Combine
import UIKit

/// Orchestrates the Pro Scan second pass: the raw ARKit session, its
/// derived point cloud store, performance metrics, and capture-flow
/// haptics. Owned by `CaptureView` alongside (never concurrently with) the
/// existing RoomPlan `CaptureCoordinator`.
@MainActor
final class ProScanCoordinator: ObservableObject {
    @Published private(set) var isRunning = false
    @Published var isMeshVisible = true
    @Published var failureMessage: String?

    let performanceMonitor = PerformanceMonitor()
    let pointCloudStore = PointCloudStore()

    private let arSession = ARPointCloudSession()
    var session: ARSession { arSession.session }
    private let hapticEngine = HapticEngineManager()
    private(set) lazy var haptics = HapticFeedbackAdapter(engineManager: hapticEngine)

    private var wasTrackingDegraded = false
    private var meshCountTimer: Timer?

    static var isSupported: Bool { ARPointCloudSession.isSupported }

    init() {
        arSession.onFrame = { [weak self] frame in
            guard let self else { return }
            Task { @MainActor in
                self.pointCloudStore.ingest(frame)
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

        // Reports the count that will actually be exported (the fused mesh,
        // not the raw per-frame depth) — polled rather than pushed, since
        // it only needs to be roughly live for the HUD, not per-frame.
        meshCountTimer?.invalidate()
        meshCountTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let count = self.arSession.currentMeshPoints().count
            Task { @MainActor in
                self.performanceMonitor.reportPointCount(count)
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        arSession.stop()
        performanceMonitor.stop()
        hapticEngine.stop()
        meshCountTimer?.invalidate()
        meshCountTimer = nil
        isRunning = false
    }

    func confirmMeshClosed() {
        haptics.meshClosed()
    }

    /// The scan to actually export/visualize: ARKit's fused mesh
    /// reconstruction rather than the raw per-frame depth accumulated in
    /// `pointCloudStore` (that one only drives the sampling-tick haptic and
    /// coverage-adjacent HUD signal during capture).
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
