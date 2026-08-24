import SwiftUI
import MetalKit

/// SwiftUI wrapper for the Metal point-cloud/heatmap view, bound to a
/// `ProScanCoordinator`'s ring buffer. Renders continuously at a capped
/// frame rate to bound GPU work during capture.
struct PointCloudMetalView: UIViewRepresentable {
    let ringBuffer: PointCloudRingBuffer

    /// Shared between the view and its renderer so both draw against the
    /// same `MTLDevice` instance — buffers made on one device are not valid
    /// to draw with another.
    private let device = MTLCreateSystemDefaultDevice()

    func makeCoordinator() -> MetalPointCloudRenderer? {
        guard let device else { return nil }
        return MetalPointCloudRenderer(device: device, ringBuffer: ringBuffer)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = device
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
