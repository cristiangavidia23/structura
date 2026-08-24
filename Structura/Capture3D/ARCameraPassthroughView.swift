import SwiftUI
import ARKit
import SceneKit

/// Live camera background for the Pro Scan session, so the confidence
/// heatmap draws over the actual room instead of floating on plain black.
/// Shares the same `ARSession` that `ARPointCloudSession` already runs and
/// is the delegate of — `ARSCNView` only reads frames to render the camera
/// image, it doesn't take over or compete with that delegate.
struct ARCameraPassthroughView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        view.automaticallyUpdatesLighting = false
        view.scene = SCNScene()
        view.antialiasingMode = .none
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
