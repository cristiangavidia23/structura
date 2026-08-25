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
    @Published private(set) var elapsedSeconds: Int = 0
    @Published private(set) var isRunningLong = false

    /// Pro Scan has no loop closure or relocalization — ARKit's estimated
    /// position just keeps drifting the longer and further a pass runs,
    /// which visibly warps the captured geometry. There's no code fix for
    /// that within a single short ARKit session, so the practical mitigation
    /// is keeping passes short: nudge the user once a scan runs long enough
    /// that drift is likely to be noticeable.
    static let recommendedMaxDuration = 40

    let performanceMonitor = PerformanceMonitor()
    let pointCloudStore = PointCloudStore()

    private let arSession = ARPointCloudSession()
    var session: ARSession { arSession.session }
    private let hapticEngine = HapticEngineManager()
    private(set) lazy var haptics = HapticFeedbackAdapter(engineManager: hapticEngine)

    private var wasTrackingDegraded = false
    private var meshCountTimer: Timer?
    private var startedAt: Date?

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
        elapsedSeconds = 0
        isRunningLong = false
        startedAt = Date()

        // Reports the count that will actually be exported (the fused mesh,
        // not the raw per-frame depth) — polled rather than pushed, since
        // it only needs to be roughly live for the HUD, not per-frame. Also
        // where elapsed duration is tracked, to nudge the user once drift
        // is likely to have become noticeable.
        meshCountTimer?.invalidate()
        meshCountTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let count = self.arSession.currentMeshPoints().count
            Task { @MainActor in
                self.performanceMonitor.reportPointCount(count)
                self.tickElapsed()
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
        startedAt = nil
        isRunning = false
    }

    private func tickElapsed() {
        guard let startedAt else { return }
        elapsedSeconds = Int(Date().timeIntervalSince(startedAt))
        if elapsedSeconds == Self.recommendedMaxDuration && !isRunningLong {
            isRunningLong = true
            haptics.trackingLostProgressive()
        }
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
