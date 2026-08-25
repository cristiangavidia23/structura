import SwiftUI
import RoomPlan

final class CaptureCoordinator: NSObject, ObservableObject, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
    weak var captureView: RoomCaptureView?
    @Published var errorMessage: String?
    /// Live guidance RoomPlan itself emits during scanning ("move closer",
    /// "slow down"...) — surfacing it is the highest-leverage thing we can do
    /// for scan quality, since it's the same signal that decides how much of
    /// the room ends up inferred instead of actually measured.
    @Published var instructionText: String?
    /// Fires once per room, whether it's the first or the fourth — multi-room
    /// capture is just calling `start()` again after this instead of finishing.
    var onRoomFinished: ((CapturedRoom) -> Void)?

    override init() {
        super.init()
    }

    // RoomCaptureViewDelegate inherits from NSCoding; not used for real archiving.
    required init?(coder: NSCoder) {
        super.init()
    }

    func encode(with coder: NSCoder) {}

    func start() {
        guard let captureView else { return }
        var configuration = RoomCaptureSession.Configuration()
        // Apple's own tracking-calibration guidance overlay — the single
        // biggest lever RoomPlan exposes for scan quality, since a lot of
        // imprecision comes from starting the scan before ARKit has a good
        // initial fix rather than from anything during the scan itself.
        configuration.isCoachingEnabled = true
        captureView.captureSession.run(configuration: configuration)
    }

    func stop() {
        captureView?.captureSession.stop()
    }

    // MARK: RoomCaptureSessionDelegate

    func captureSession(_ session: RoomCaptureSession, didFail error: Error) {
        DispatchQueue.main.async {
            self.errorMessage = error.localizedDescription
        }
    }

    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        let text = Self.text(for: instruction)
        DispatchQueue.main.async {
            // A tactile nudge alongside the banner: RoomPlan's own
            // instructions ("slow down", "move closer"...) are the most
            // direct signal for scan precision, and most of them fire while
            // the user is looking at the room, not at the on-screen text.
            if text != nil, self.instructionText == nil {
                Haptics.warning()
            }
            self.instructionText = text
        }
    }

    private static func text(for instruction: RoomCaptureSession.Instruction) -> String? {
        switch instruction {
        case .moveCloseToWall: return "Acércate más a la pared"
        case .moveAwayFromWall: return "Aléjate un poco de la pared"
        case .slowDown: return "Muévete más despacio"
        case .turnOnLight: return "Hay poca luz — enciende una lámpara"
        case .lowTexture: return "Apunta a una superficie con más detalle"
        case .normal: return nil
        @unknown default: return nil
        }
    }

    // MARK: RoomCaptureViewDelegate

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        error == nil
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        if let error {
            DispatchQueue.main.async {
                self.errorMessage = error.localizedDescription
            }
            return
        }
        DispatchQueue.main.async {
            self.onRoomFinished?(processedResult)
        }
    }
}

struct RoomCaptureRepresentable: UIViewRepresentable {
    @ObservedObject var coordinator: CaptureCoordinator

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero)
        view.captureSession.delegate = coordinator
        view.delegate = coordinator
        coordinator.captureView = view
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}
