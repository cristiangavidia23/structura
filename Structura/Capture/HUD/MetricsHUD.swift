import SwiftUI
import ARKit

/// Floating glass metrics pill shown during Pro Scan: FPS, RAM, point count,
/// and ARKit tracking state — the "is this scan actually good" readout.
struct MetricsHUD: View {
    @ObservedObject var monitor: PerformanceMonitor

    var body: some View {
        HStack(spacing: 14) {
            metric(systemImage: "waveform.path.ecg", value: "\(Int(monitor.fps.rounded())) fps")
            metric(systemImage: "memorychip", value: "\(Int(monitor.memoryUsedMB.rounded())) MB")
            metric(systemImage: "aqi.medium", value: monitor.pointCount.formatted())
            trackingBadge
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(HUDStyle.glass, in: Capsule())
        .overlay(Capsule().strokeBorder(HUDStyle.panelStroke))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }

    private func metric(systemImage: String, value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption2)
            Text(value)
                .font(.caption2.monospacedDigit().weight(.semibold))
        }
        .foregroundStyle(.white)
    }

    private var trackingBadge: some View {
        let (color, label) = trackingDescription
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.white)
    }

    private var trackingDescription: (Color, String) {
        switch monitor.trackingState {
        case .normal:
            return (.green, "Normal")
        case .limited(let reason):
            switch reason {
            case .relocalizing: return (.yellow, "Relocalizando")
            case .initializing: return (.yellow, "Iniciando")
            case .excessiveMotion: return (.yellow, "Muy rápido")
            case .insufficientFeatures: return (.yellow, "Poco detalle")
            @unknown default: return (.yellow, "Limitado")
            }
        case .notAvailable:
            return (.red, "Sin tracking")
        }
    }
}
