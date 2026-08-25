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
                }
                .onDisappear { proScan.stop() }
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

    private var cancelButton: some View {
        Button {
            proScan.stop()
            dismiss()
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
        let exportPoints = proScan.currentMeshPoints()
        let directory = store.scansDirectory
        let baseName = "\(record.id.uuidString)_pointcloud"

        Task {
            let coordinate = await PointCloudLocationProvider().requestLocation()
            let metadata = PointCloudExportMetadata(capturedAt: Date(), location: coordinate, pointCount: exportPoints.count)
            let coordinator = PointCloudExportCoordinator()
            var plyURL: URL?
            var lasURL: URL?
            do {
                plyURL = try await coordinator.export(points: exportPoints, metadata: metadata, format: .ply, to: directory, baseName: baseName)
                lasURL = try await coordinator.export(points: exportPoints, metadata: metadata, format: .las, to: directory, baseName: baseName)
            } catch {
                await MainActor.run {
                    isExporting = false
                    exportError = error.localizedDescription
                }
                return
            }

            let location = coordinate.map { (lat: $0.latitude, lon: $0.longitude) }
            await MainActor.run {
                store.attachPointCloud(plyURL: plyURL, lasURL: lasURL, location: location, to: record)
                isExporting = false
                onFinished()
                dismiss()
            }
        }
    }
}
