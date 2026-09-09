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

    /// `true` while an interruption may have shifted the coordinate origin
    /// and sustained tracking hasn't yet confirmed it's safe again — see
    /// `ARPointCloudSession.onCoordinateFrameBrokenStateChanged`. The UI
    /// should show this as "reubicando…", not silently keep scanning as if
    /// nothing happened.
    @Published private(set) var isCoordinateFrameBroken = false

    /// Why the coordinator stopped itself without the user tapping
    /// anything — set by the once-a-second resource guard check, never
    /// cleared automatically (a fresh `start()` resets it). `nil` means
    /// the capture is still running normally or was stopped by the user.
    enum StopReason: Equatable {
        case lowStorage
        case lowBattery
        case criticalThermalState

        var message: String {
            switch self {
            case .lowStorage:
                return "Poco espacio de almacenamiento disponible. El escaneo se detuvo para no perder lo capturado."
            case .lowBattery:
                return "Batería baja. El escaneo se detuvo para no perder lo capturado."
            case .criticalThermalState:
                return "El dispositivo se está sobrecalentando. El escaneo se detuvo para proteger el hardware y no perder lo capturado."
            }
        }
    }
    @Published private(set) var stopReason: StopReason?

    /// Once-a-second sample count of "was tracking degraded at this tick" —
    /// a coarse, honest tracking-quality signal for `ScanMetadataReport`.
    /// Not a continuous integral (only as fine-grained as the 1 s poll
    /// already driving `tickElapsed()`), but enough to distinguish "tracking
    /// was fine throughout" from "this scan had real interruptions" without
    /// fabricating a precision this coordinator doesn't actually have.
    private(set) var trackingDegradedTickCount: Int = 0

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
        arSession.onCoordinateFrameBrokenStateChanged = { [weak self] isBroken in
            Task { @MainActor in
                self?.isCoordinateFrameBroken = isBroken
            }
        }
    }

    func start(viewportSize: CGSize, interfaceOrientation: UIInterfaceOrientation) {
        guard Self.isSupported, !isRunning else { return }
        pointCloudStore.reset()
        performanceMonitor.start()
        hapticEngine.start()
        // Needed for `UIDevice.current.batteryLevel`/`.batteryState` to
        // report real values at all — without this they're always -1/`.unknown`.
        UIDevice.current.isBatteryMonitoringEnabled = true
        arSession.start(viewportSize: viewportSize, interfaceOrientation: interfaceOrientation)
        isRunning = true
        elapsedSeconds = 0
        isRunningLong = false
        trackingDegradedTickCount = 0
        isCoordinateFrameBroken = false
        stopReason = nil
        startedAt = Date()

        // Reports the count that will actually be exported (the fused mesh,
        // not the raw per-frame depth) — polled rather than pushed, since
        // it only needs to be roughly live for the HUD, not per-frame. Also
        // where elapsed duration is tracked, to nudge the user once drift
        // is likely to have become noticeable.
        //
        // Uses the O(1) incremental counter, not `currentMeshPoints().count`
        // — the latter copies every point in the scan just to discard them,
        // every second, under the same lock the mesh-processing pipeline
        // needs (a real contributor to delegate-queue backlog on large
        // scans, per the Pro Scan audit).
        meshCountTimer?.invalidate()
        meshCountTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let count = self.arSession.currentMeshPointCount()
            Task { @MainActor in
                self.performanceMonitor.reportPointCount(count)
                self.tickElapsed()
                self.checkResourceGuards()
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
        if wasTrackingDegraded {
            trackingDegradedTickCount += 1
        }
        if elapsedSeconds == Self.recommendedMaxDuration && !isRunningLong {
            isRunningLong = true
            haptics.trackingLostProgressive()
        }
    }

    func confirmMeshClosed() {
        haptics.meshClosed()
    }

    /// Checked once a second alongside `tickElapsed()` — a device running
    /// low on storage, unplugged with low battery, or thermally critical is
    /// at real risk of losing an in-progress scan outright (a crash, an OS
    /// force-quit, or ARKit itself throttling). Stopping proactively, while
    /// whatever has been captured so far can still be exported, is the
    /// recovery path — never a silent loss.
    private func checkResourceGuards() {
        guard isRunning, stopReason == nil else { return }

        if let availableBytes = Self.availableDiskSpaceBytes(), availableBytes < ProScanConfig.minimumFreeDiskSpaceBytes {
            stopReason = .lowStorage
            return
        }

        let device = UIDevice.current
        if device.batteryState == .unplugged, device.batteryLevel >= 0, device.batteryLevel < ProScanConfig.minimumBatteryLevelWhileUnplugged {
            stopReason = .lowBattery
            return
        }

        if ProScanConfig.shouldAbortCapture(forThermalState: ProcessInfo.processInfo.thermalState) {
            stopReason = .criticalThermalState
        }
    }

    private static func availableDiskSpaceBytes() -> Int64? {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let values = try? documentsURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// The scan to actually export/visualize: ARKit's fused mesh
    /// reconstruction rather than the raw per-frame depth accumulated in
    /// `pointCloudStore` (that one only drives the sampling-tick haptic and
    /// coverage-adjacent HUD signal during capture).
    /// - Parameter authoritative: pass `true` only at the final export, to
    ///   rebuild the fused set from scratch and shed any floating-point
    ///   residue a capture's worth of incremental record/remove cycles left
    ///   behind. The autosave path must leave it `false` — rebuilding on a
    ///   timer is finding C1 of the architecture audit.
    func currentMeshPoints(authoritative: Bool = false) -> [PointCloudExportPoint] {
        arSession.currentMeshPoints(authoritative: authoritative)
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
