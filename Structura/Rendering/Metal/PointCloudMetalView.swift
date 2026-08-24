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
        view.delegate = renderer
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
