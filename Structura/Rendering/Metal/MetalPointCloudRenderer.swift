import MetalKit
import simd

/// Renders the latest point cloud frame from the ring buffer as a
/// confidence-colored heatmap. Reads the buffer's latest completed slot on
/// every `draw(in:)` without blocking the ARKit capture thread that writes
/// it (see `PointCloudRingBuffer`).
///
/// Draws with the ARKit camera's own view/projection matrices for that
/// frame rather than a synthetic orbit camera — the points were unprojected
/// from that exact camera, so they're guaranteed to sit inside its frustum
/// instead of occasionally landing off-screen or behind a wandering
/// synthetic viewpoint.
final class MetalPointCloudRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private let ringBuffer: PointCloudRingBuffer

    private var vertexBuffer: MTLBuffer?
    private var vertexCount = 0

    init?(device: MTLDevice, ringBuffer: PointCloudRingBuffer) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        self.ringBuffer = ringBuffer
        super.init()
        buildPipeline()
    }

    /// Never fatal: if the shader library or pipeline fails to build for any
    /// reason, Pro Scan should keep capturing and exporting points — it
    /// just won't have a live heatmap overlay. Crashing the whole capture
    /// flow over a rendering nicety is a worse failure mode than a blank
    /// preview.
    private func buildPipeline() {
        guard let library = device.makeDefaultLibrary() ?? (try? device.makeDefaultLibrary(bundle: .main)) else {
            print("Structura: Metal default library not found — point cloud heatmap disabled")
            return
        }
        guard let vertexFunction = library.makeFunction(name: "pointCloudVertex"),
              let fragmentFunction = library.makeFunction(name: "pointCloudFragment") else {
            print("Structura: pointCloudVertex/pointCloudFragment not found in Shaders.metal — point cloud heatmap disabled")
            return
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("Structura: point cloud pipeline state creation failed: \(error) — heatmap disabled")
        }
    }

    private func uploadLatestFrame() -> PointCloudFrame {
        let frame = ringBuffer.readLatest()
        guard !frame.positions.isEmpty else {
            vertexCount = 0
            return frame
        }

        var vertices = [PointVertex]()
        vertices.reserveCapacity(frame.positions.count)
        for i in 0..<frame.positions.count {
            vertices.append(PointVertex(position: frame.positions[i], confidence: frame.confidences[i]))
        }

        let length = vertices.count * MemoryLayout<PointVertex>.stride
        vertexBuffer = device.makeBuffer(bytes: vertices, length: length, options: .storageModeShared)
        vertexCount = vertices.count
        return frame
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let frame = uploadLatestFrame()

        guard let pipelineState,
              let vertexBuffer,
              vertexCount > 0,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        var uniforms = PointCloudUniforms(
            viewProjectionMatrix: frame.projectionMatrix * frame.viewMatrix,
            pointSize: 8
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<PointCloudUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: vertexCount)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
