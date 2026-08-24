import SwiftUI
import UIKit

/// The Pro Scan second pass: a standalone full-screen capture using raw
/// ARKit + Metal, run only after RoomPlan's session has fully stopped (see
/// plan notes on ARKit's single-active-session constraint). Produces a
/// dense, confidence-heatmapped point cloud exported to PLY/LAS and
/// attached to the existing scan record.
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

                    if proScan.isHeatmapVisible {
                        PointCloudMetalView(ringBuffer: proScan.ringBuffer)
                            .ignoresSafeArea()
                    }

                    cancelButton
                        .frame(maxHeight: .infinity, alignment: .top)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    MetricsHUD(monitor: proScan.performanceMonitor)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 16)

                    RadialToolMenu(items: [
                        RadialToolItem(systemImage: "aqi.medium", isActive: proScan.isHeatmapVisible) {
                            proScan.isHeatmapVisible.toggle()
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
            } else {
                unsupportedDevice
            }
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
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

        let exportPoints = zip(proScan.pointCloudStore.accumulatedPositions, proScan.pointCloudStore.accumulatedConfidences)
            .map { PointCloudExportPoint(position: $0.0, confidence: $0.1) }
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
