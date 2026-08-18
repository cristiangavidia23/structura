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

    private var overlay: some View {
        HStack {
            Button {
                coordinator.stop()
                dismiss()
            } label: {
                Text("Cancelar")
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(.black.opacity(0.55), in: Capsule())
            }

            Spacer()

            Button {
                coordinator.stop()
            } label: {
                Text("Listo")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 44)
                    .background(Color(red: 0.93, green: 0.88, blue: 0.78), in: Capsule())
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
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
