import SwiftUI
import ARKit
import RealityKit

/// Live camera background for the Pro Scan session, with ARKit's own scene
/// mesh drawn over it as it's reconstructed in real time — RealityKit's
/// built-in scene-understanding visualization, filling in as the fused
/// `ARMeshAnchor` geometry (what `ARPointCloudSession` also reads for
/// export) grows. Shares the same `ARSession` that `ARPointCloudSession`
/// already runs and is the delegate of — `ARView` only reads frames to
/// render, it doesn't take over or compete with that delegate.
struct ARCameraPassthroughView: UIViewRepresentable {
    let session: ARSession
    var isMeshVisible: Bool

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.session = session
        view.automaticallyConfigureSession = false
        view.debugOptions = isMeshVisible ? [.showSceneUnderstanding] : []
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        uiView.debugOptions = isMeshVisible ? [.showSceneUnderstanding] : []
    }
}
