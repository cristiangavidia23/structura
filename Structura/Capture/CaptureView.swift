import SwiftUI
import RoomPlan

struct CaptureView: View {
    @StateObject private var coordinator = CaptureCoordinator()
    @Environment(\.dismiss) private var dismiss

    var onFinish: (CapturedStructure) -> Void

    /// Rooms captured so far this session. Multi-room is just "keep scanning
    /// instead of finishing" — every capture, including a single room, ends by
    /// building a CapturedStructure from whatever accumulated here.
    @State private var capturedRooms: [CapturedRoom] = []
    @State private var isPresentingRoomChoice = false
    @State private var isBuildingStructure = false
    @State private var buildErrorMessage: String?

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

                    roomBadge
                        .frame(maxHeight: .infinity, alignment: .top)
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    if let instruction = coordinator.instructionText {
                        instructionBanner(instruction)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if isBuildingStructure {
                        buildingOverlay
                    } else if !isPresentingRoomChoice {
                        overlay
                    }

                    if isPresentingRoomChoice {
                        Color.black.opacity(0.35)
                            .ignoresSafeArea()
                            .transition(.opacity)

                        roomChoiceCard
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: coordinator.instructionText)
                .animation(HUDStyle.popSpring, value: isPresentingRoomChoice)
                .onAppear {
                    coordinator.onRoomFinished = { room in
                        capturedRooms.append(room)
                        isPresentingRoomChoice = true
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
                .alert("No se pudo combinar los ambientes", isPresented: buildErrorPresented) {
                    Button("Cerrar", role: .cancel) { dismiss() }
                } message: {
                    Text(buildErrorMessage ?? "")
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

    private var buildErrorPresented: Binding<Bool> {
        Binding(
            get: { buildErrorMessage != nil },
            set: { isPresented in if !isPresented { buildErrorMessage = nil } }
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

    private var roomBadge: some View {
        Text("Ambiente \(capturedRooms.count + 1)")
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.5), in: Capsule())
            .padding(.trailing, 20)
            .padding(.top, 16)
    }

    private func instructionBanner(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Theme.accent.opacity(0.92), in: Capsule())
            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            .padding(.horizontal, 60)
            .padding(.top, 68)
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

    private var buildingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text("Combinando ambientes…")
                .font(.subheadline)
                .foregroundStyle(.white)
        }
        .padding(.bottom, 40)
    }

    private var roomChoiceCard: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(Theme.ink.opacity(0.2))
                .frame(width: 36, height: 5)
                .padding(.top, 10)

            VStack(spacing: 4) {
                Text(capturedRooms.count == 1 ? "Ambiente escaneado" : "\(capturedRooms.count) ambientes escaneados")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Text("¿Quieres escanear otro ambiente de la misma propiedad, o ya terminaste?")
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink.opacity(0.6))
                    .multilineTextAlignment(.center)
            }

            Button {
                isPresentingRoomChoice = false
                coordinator.start()
            } label: {
                Text("Agregar otro ambiente")
            }
            .buttonStyle(.primary)

            Button {
                isPresentingRoomChoice = false
                finish()
            } label: {
                Text("Finalizar")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.ink)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
    }

    /// StructureBuilder needs at least one room; it's what turns "just scan"
    /// and "scan a whole house" into the same code path.
    private func finish() {
        isBuildingStructure = true
        Task {
            do {
                let structure = try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: capturedRooms)
                isBuildingStructure = false
                onFinish(structure)
                dismiss()
            } catch {
                isBuildingStructure = false
                buildErrorMessage = error.localizedDescription
            }
        }
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
