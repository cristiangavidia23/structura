import SwiftUI
import MetalKit

/// SwiftUI wrapper for the Metal point-cloud/heatmap view, bound to a
/// `ProScanCoordinator`'s ring buffer. Renders continuously at a capped
/// frame rate to bound GPU work during capture.
struct PointCloudMetalView: UIViewRepresentable {
    let ringBuffer: PointCloudRingBuffer

    func makeCoordinator() -> MetalPointCloudRenderer? {
        MetalPointCloudRenderer(ringBuffer: ringBuffer)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 30
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.backgroundColor = .clear
        view.isOpaque = false
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
