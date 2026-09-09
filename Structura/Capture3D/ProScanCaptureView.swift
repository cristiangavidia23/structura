import SwiftUI
import UIKit

/// The Pro Scan second pass: a standalone full-screen capture using raw
/// ARKit, run only after RoomPlan's session has fully stopped (see plan
/// notes on ARKit's single-active-session constraint). Produces a dense,
/// real-color point cloud (from ARKit's fused mesh reconstruction) exported
/// to PLY/LAS and attached to the existing scan record.
struct ProScanCaptureView: View {
    let record: ScanRecord
    let store: ScanStore
    var onFinished: () -> Void

    @StateObject private var proScan = ProScanCoordinator()
    @Environment(\.dismiss) private var dismiss
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var isConfirmingCancel = false
    @State private var autosaveTask: Task<Void, Never>?

    var body: some View {
        Group {
            if ProScanCoordinator.isSupported {
                ZStack(alignment: .bottom) {
                    Color.black.ignoresSafeArea()

                    ARCameraPassthroughView(session: proScan.session, isMeshVisible: proScan.isMeshVisible)
                        .ignoresSafeArea()

                    cancelButton
                        .frame(maxHeight: .infinity, alignment: .top)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 8) {
                        MetricsHUD(monitor: proScan.performanceMonitor)
                        guidanceBanner
                        if proScan.isCoordinateFrameBroken {
                            relocalizingBanner
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 16)

                    RadialToolMenu(items: [
                        RadialToolItem(systemImage: "square.grid.3x3", isActive: proScan.isMeshVisible) {
                            proScan.isMeshVisible.toggle()
                        },
                        RadialToolItem(systemImage: "checkmark.circle", isActive: false) {
                            proScan.confirmMeshClosed()
                            finish()
                        }
                    ])
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(24)

                    if isExporting {
                        VStack(spacing: 12) {
                            ProgressView().tint(.white)
                            Text("Exportando nube de puntos…")
                                .font(.subheadline)
                                .foregroundStyle(.white)
                        }
                        .padding(.bottom, 100)
                    }
                }
                .onAppear {
                    let scene = UIApplication.shared.connectedScenes
                        .compactMap { $0 as? UIWindowScene }
                        .first
                    proScan.start(
                        viewportSize: UIScreen.main.bounds.size,
                        interfaceOrientation: scene?.interfaceOrientation ?? .portrait
                    )
                    startAutosaveLoop()
                }
                .onDisappear {
                    autosaveTask?.cancel()
                    autosaveTask = nil
                    proScan.stop()
                }
                .onChange(of: proScan.stopReason) { _, stopReason in
                    // The coordinator stopped itself (low storage/battery/
                    // thermal) — finish and export whatever was captured
                    // rather than let the session just sit paused.
                    guard stopReason != nil, !isExporting else { return }
                    finish()
                }
                .alert("No se pudo exportar", isPresented: errorPresented) {
                    Button("Cerrar", role: .cancel) { exportError = nil }
                } message: {
                    Text(exportError ?? "")
                }
                .alert("Pro Scan se interrumpió", isPresented: failurePresented) {
                    Button("Cerrar", role: .cancel) { proScan.failureMessage = nil }
                } message: {
                    Text(proScan.failureMessage ?? "")
                }
                .alert("Escaneo detenido", isPresented: stopReasonPresented) {
                    Button("Cerrar", role: .cancel) {}
                } message: {
                    Text(proScan.stopReason?.message ?? "")
                }
                .confirmationDialog(
                    "¿Cancelar este escaneo?",
                    isPresented: $isConfirmingCancel,
                    titleVisibility: .visible
                ) {
                    Button("Descartar escaneo", role: .destructive) {
                        proScan.stop()
                        dismiss()
                    }
                    Button("Seguir escaneando", role: .cancel) {}
                } message: {
                    Text("Vas a perder el progreso de este pase de Pro Scan.")
                }
            } else {
                unsupportedDevice
            }
        }
    }

    /// Pro Scan has no loop closure — the longer and further a pass runs,
    /// the more its estimated position can drift and visibly warp the
    /// result. There's no code fix for that within a single short ARKit
    /// session, so the practical mitigation is keeping passes short and
    /// deliberate; this nudges toward that instead of silently producing a
    /// warped scan with no explanation.
    private var guidanceBanner: some View {
        Group {
            if proScan.isRunningLong {
                Label("Escaneo largo — termina pronto para evitar más desalineación", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            } else {
                Label("Muévete despacio, en un área pequeña, con buena luz", systemImage: "info.circle")
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
        .animation(.easeInOut, value: proScan.isRunningLong)
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
    }

    private var failurePresented: Binding<Bool> {
        Binding(get: { proScan.failureMessage != nil }, set: { if !$0 { proScan.failureMessage = nil } })
    }

    private var stopReasonPresented: Binding<Bool> {
        Binding(get: { proScan.stopReason != nil }, set: { _ in })
    }

    /// A vanilla `ARSession` gives no hard guarantee the coordinate origin
    /// survived an interruption intact (see `ARPointCloudSession`) — this
    /// mirrors that caution to the user instead of silently looking like
    /// scanning has resumed normally the instant ARKit reports `.normal`.
    private var relocalizingBanner: some View {
        Label("Reubicando… espera antes de seguir escaneando", systemImage: "location.slash.fill")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.yellow)
    }

    private var cancelButton: some View {
        Button {
            // No progress worth confirming yet if the user just opened Pro
            // Scan and immediately backed out.
            if proScan.elapsedSeconds > 2 {
                isConfirmingCancel = true
            } else {
                proScan.stop()
                dismiss()
            }
        } label: {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.5), in: Circle())
        }
        .padding(.leading, 20)
        .padding(.top, 8)
        .accessibilityLabel("Cancelar")
    }

    private var unsupportedDevice: some View {
        VStack(spacing: 12) {
            Image(systemName: "arkit")
                .font(.system(size: 40))
            Text("Este dispositivo no soporta Pro Scan")
                .font(.headline)
            Button("Cerrar") { dismiss() }
                .padding(.top, 8)
        }
        .padding()
    }

    private func finish() {
        proScan.stop()
        isExporting = true

        // ARKit's fused mesh reconstruction, not the raw per-frame depth
        // that only drives the live heatmap overlay — meaningfully more
        // stable since it's built by integrating many frames over time.
        // `authoritative:` rebuilds the fused set from every stored sample
        // rather than reading the incrementally-maintained one. It costs
        // O(points) — paid once, here, where the file the user keeps is
        // being written — and guarantees the export carries no
        // floating-point residue from the capture's record/remove cycles.
        // The autosave below deliberately does *not* pass it.
        let exportPoints = proScan.currentMeshPoints(authoritative: true)
        let directory = store.scansDirectory
        let baseName = "\(record.id.uuidString)_pointcloud"

        // Captured before the coordinator resets on its next `start()` —
        // `stop()` above leaves these values in place from this session.
        let durationSeconds = proScan.elapsedSeconds
        let trackingDegradedTickCount = proScan.trackingDegradedTickCount

        Task {
            let coordinate = await PointCloudLocationProvider().requestLocation()
            let metadata = PointCloudExportMetadata(capturedAt: Date(), location: coordinate, pointCount: exportPoints.count)
            let coordinator = PointCloudExportCoordinator()
            var plyURL: URL?
            var lasURL: URL?
            var metadataReport: ScanMetadataReport?
            do {
                plyURL = try await coordinator.export(points: exportPoints, metadata: metadata, format: .ply, to: directory, baseName: baseName)
                lasURL = try await coordinator.export(points: exportPoints, metadata: metadata, format: .las, to: directory, baseName: baseName)
                // Best-effort: a failure here shouldn't take down an
                // otherwise-successful PLY/LAS export, so it's isolated
                // from the `do`/`catch` above that gates those two.
                metadataReport = try? await coordinator.writeMetadataReport(
                    points: exportPoints,
                    metadata: metadata,
                    durationSeconds: durationSeconds,
                    trackingDegradedTickCount: trackingDegradedTickCount,
                    coordinateReferenceSystem: "Local ENU frame, arbitrary horizontal orientation, vertical aligned to gravity — see the accompanying .las file's WKT VLR",
                    controlPointDeclaredAccuracyMeters: nil,
                    to: directory,
                    baseName: baseName
                )
            } catch {
                await MainActor.run {
                    isExporting = false
                    exportError = error.localizedDescription
                }
                return
            }

            let location = coordinate.map { (lat: $0.latitude, lon: $0.longitude) }
            // Mirrors a subset of the just-written `ScanMetadataReport` onto
            // `ScanRecord` so `ResultView` can show it without re-parsing a
            // PLY that can hold hundreds of thousands of points.
            let quality = metadataReport.map {
                PointCloudQualitySummary(
                    durationSeconds: $0.durationSeconds,
                    trackingQuality: $0.trackingQuality,
                    pointCount: $0.pointCount,
                    meanConfidence: $0.meanConfidence
                )
            }
            await MainActor.run {
                store.attachPointCloud(plyURL: plyURL, lasURL: lasURL, location: location, quality: quality, to: record)
                isExporting = false
                onFinished()
                dismiss()
            }
        }
    }

    /// Periodically snapshots the in-progress mesh to the scan's PLY —
    /// updating the existing `ScanRecord` in place, not a separate
    /// "recovery" file — so a scan survives the app being killed outright,
    /// not just backgrounded: if `finish()` never runs, whatever was last
    /// autosaved stays attached as the record's point cloud. LAS/metadata
    /// are only written at the real finish (cheaper to skip them here, and
    /// the app's own PLY viewer is all an autosave needs to serve).
    private func startAutosaveLoop() {
        autosaveTask?.cancel()
        autosaveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(ProScanConfig.autosaveIntervalSeconds * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await autosave()
            }
        }
    }

    private func autosave() async {
        guard proScan.isRunning else { return }
        let points = proScan.currentMeshPoints()
        guard !points.isEmpty else { return }

        let metadata = PointCloudExportMetadata(capturedAt: Date(), location: nil, pointCount: points.count)
        let coordinator = PointCloudExportCoordinator()
        guard let plyURL = try? await coordinator.export(
            points: points, metadata: metadata, format: .ply,
            to: store.scansDirectory, baseName: "\(record.id.uuidString)_pointcloud"
        ) else { return }

        await MainActor.run {
            store.attachPointCloud(plyURL: plyURL, lasURL: nil, location: nil, to: record)
        }
    }
}
