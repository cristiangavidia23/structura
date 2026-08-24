import SwiftUI
import MetalKit

/// SwiftUI wrapper for the Metal point-cloud/heatmap view, bound to a
/// `ProScanCoordinator`'s ring buffer. Renders continuously at a capped
/// frame rate to bound GPU work during capture.
struct PointCloudMetalView: UIViewRepresentable {
    let renderer: MetalPointCloudRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = renderer.device
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 30
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.backgroundColor = .clear
        view.isOpaque = false
        // `isOpaque`/`backgroundColor` only affect UIKit-level compositing.
        // Metal's own render pass still clears to opaque black by default
        // (alpha 1) on every draw, which would paint over the camera
        // passthrough behind it regardless — clear to transparent instead.
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.layer.isOpaque = false
        view.delegate = renderer
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
