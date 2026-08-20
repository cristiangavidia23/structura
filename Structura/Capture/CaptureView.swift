import SwiftUI
import RoomPlan

struct CaptureView: View {
    @StateObject private var coordinator = CaptureCoordinator()
    @Environment(\.dismiss) private var dismiss

    var onFinish: (CapturedRoom) -> Void

    var body: some View {
        Group {
            if RoomCaptureSession.isSupported {
                ZStack(alignment: .bottom) {
                    RoomCaptureRepresentable(coordinator: coordinator)
                        .ignoresSafeArea()

                    CornerBrackets(color: .white.opacity(0.5), length: 22, thickness: 1.5, inset: 28)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)

                    cancelButton
                        .frame(maxHeight: .infinity, alignment: .top)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    overlay
                }
                .onAppear {
                    coordinator.onFinish = { room in
                        onFinish(room)
                        dismiss()
                    }
                    coordinator.start()
                }
                .onDisappear {
                    coordinator.stop()
                }
                .alert("No se pudo completar el escaneo", isPresented: errorPresented) {
                    Button("Cerrar", role: .cancel) { dismiss() }
                } message: {
                    Text(coordinator.errorMessage ?? "")
                }
            } else {
                unsupportedDevice
            }
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { coordinator.errorMessage != nil },
            set: { isPresented in
                if !isPresented { coordinator.errorMessage = nil }
            }
        )
    }

    private var cancelButton: some View {
        Button {
            coordinator.stop()
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

    private var overlay: some View {
        Button {
            Haptics.tap()
            coordinator.stop()
        } label: {
            Text("Listo")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .frame(minHeight: 50)
                .background(Theme.accent, in: Capsule())
                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        }
        .padding(.bottom, 28)
    }

    private var unsupportedDevice: some View {
        VStack(spacing: 12) {
            Image(systemName: "arkit")
                .font(.system(size: 40))
            Text("Este dispositivo no tiene sensor LiDAR")
                .font(.headline)
            Text("Structura necesita un iPhone o iPad con LiDAR (modelos Pro/Pro Max) para escanear ambientes.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Cerrar") { dismiss() }
                .padding(.top, 8)
        }
        .padding()
    }
}
