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
        // The debug option alone only visualizes scene understanding if the
        // subsystem is actually consuming the mesh — it stays idle
        // otherwise, no matter how many `ARMeshAnchor`s the session hands
        // out. `.occlusion` is the option Apple's own samples enable for
        // this; we don't render virtual content that needs occluding, so
        // it has no other effect here.
        view.environment.sceneUnderstanding.options.insert(.occlusion)
        view.debugOptions = isMeshVisible ? [.showSceneUnderstanding] : []
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        uiView.debugOptions = isMeshVisible ? [.showSceneUnderstanding] : []
    }
}
