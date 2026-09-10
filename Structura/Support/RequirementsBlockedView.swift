import SwiftUI

/// The screen shown instead of the app when a requirement isn't met.
///
/// One view for every blocking state rather than three near-identical ones:
/// what changes between them is the wording and whether there is anything the
/// user can do about it, not the layout.
struct RequirementsBlockedView: View {
    let state: ScanRequirements.State
    /// Re-checks the environment. Called when returning from Settings, since
    /// iOS gives the app no notification that a permission changed.
    var onRecheck: () -> Void

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()
            GraphPaperBackground().ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: symbolName)
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Theme.ink.opacity(0.55))

                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)

                Text(explanation)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                if state.offersSettingsShortcut {
                    VStack(spacing: 10) {
                        Button("Abrir Ajustes") {
                            state.openSettings()
                        }
                        .buttonStyle(.primary)

                        Button("Ya lo activé", action: onRecheck)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Theme.ink.opacity(0.6))
                    }
                    .padding(.top, 4)
                }
            }
            .padding(28)
            .overlay(CornerBrackets(color: Theme.ink.opacity(0.35)))
            .padding(.horizontal, 32)
        }
    }

    private var symbolName: String {
        switch state {
        case .unsupportedDevice: return "iphone.slash"
        case .cameraDenied, .cameraRestricted: return "camera.metering.unknown"
        case .awaitingCameraPermission, .ready: return "camera"
        }
    }

    private var title: String {
        switch state {
        case .unsupportedDevice: return "Dispositivo no compatible"
        case .cameraDenied: return "Acceso a la cámara desactivado"
        case .cameraRestricted: return "Acceso a la cámara restringido"
        case .awaitingCameraPermission, .ready: return "Acceso a la cámara"
        }
    }

    private var explanation: String {
        switch state {
        case .unsupportedDevice:
            // Names the hardware rather than blaming the user's device in the
            // abstract, so it's clear this is a capability requirement and not
            // a bug or a failed install.
            return "Structura necesita el sensor LiDAR para medir distancias reales. Este dispositivo no lo incluye, así que la captura no puede funcionar aquí."
        case .cameraDenied:
            return "Structura escanea con la cámara y el sensor LiDAR. Actívala en Ajustes para poder capturar; el escaneo se procesa en el dispositivo."
        case .cameraRestricted:
            // No Settings shortcut here on purpose: the switch exists but
            // this user is not permitted to change it.
            return "El acceso a la cámara está bloqueado por una restricción del sistema (control parental o perfil de administración). Consulta con quien administra este dispositivo."
        case .awaitingCameraPermission, .ready:
            return "Structura necesita la cámara para escanear."
        }
    }
}

#Preview("Sin LiDAR") {
    RequirementsBlockedView(state: .unsupportedDevice, onRecheck: {})
}

#Preview("Cámara denegada") {
    RequirementsBlockedView(state: .cameraDenied, onRecheck: {})
}
