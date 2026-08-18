import SwiftUI
import RoomPlan

final class CaptureCoordinator: NSObject, ObservableObject, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
    weak var captureView: RoomCaptureView?
    @Published var errorMessage: String?
    var onFinish: ((CapturedRoom) -> Void)?

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
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
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
            self.onFinish?(processedResult)
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
