import MetalKit
import simd

/// Renders the latest point cloud frame from the ring buffer as a
/// confidence-colored heatmap. Reads the buffer's latest completed slot on
/// every `draw(in:)` without blocking the ARKit capture thread that writes
/// it (see `PointCloudRingBuffer`).
final class MetalPointCloudRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private let ringBuffer: PointCloudRingBuffer

    private var vertexBuffer: MTLBuffer?
    private var vertexCount = 0

    private var orbitAngle: Float = 0

    init?(ringBuffer: PointCloudRingBuffer) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        self.ringBuffer = ringBuffer
        super.init()
        buildPipeline()
    }

    private func buildPipeline() {
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "pointCloudVertex"),
              let fragmentFunction = library.makeFunction(name: "pointCloudFragment") else { return }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func uploadLatestFrame() {
        let frame = ringBuffer.readLatest()
        guard !frame.positions.isEmpty else { return }

        var vertices = [PointVertex]()
        vertices.reserveCapacity(frame.positions.count)
        for i in 0..<frame.positions.count {
            vertices.append(PointVertex(position: frame.positions[i], confidence: frame.confidences[i]))
        }

        let length = vertices.count * MemoryLayout<PointVertex>.stride
        vertexBuffer = device.makeBuffer(bytes: vertices, length: length, options: .storageModeShared)
        vertexCount = vertices.count
    }

    private func centroid(of positions: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !positions.isEmpty else { return .zero }
        let sum = positions.reduce(SIMD3<Float>.zero, +)
        return sum / Float(positions.count)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        uploadLatestFrame()

        guard let pipelineState,
              let vertexBuffer,
              vertexCount > 0,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        let frame = ringBuffer.readLatest()
        let center = centroid(of: frame.positions)
        orbitAngle += 0.004

        let eye = center + SIMD3<Float>(sin(orbitAngle) * 3, 1.2, cos(orbitAngle) * 3)
        let viewMatrix = simd_float4x4(lookAt: eye, center: center, up: SIMD3<Float>(0, 1, 0))
        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        let projectionMatrix = simd_float4x4(perspectiveFovY: .pi / 3, aspect: aspect, near: 0.05, far: 50)

        var uniforms = PointCloudUniforms(
            viewProjectionMatrix: projectionMatrix * viewMatrix,
            pointSize: 6
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

private extension simd_float4x4 {
    init(lookAt eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) {
        let z = normalize(eye - center)
        let x = normalize(cross(up, z))
        let y = cross(z, x)
        self.init(
            SIMD4(x.x, y.x, z.x, 0),
            SIMD4(x.y, y.y, z.y, 0),
            SIMD4(x.z, y.z, z.z, 0),
            SIMD4(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
        )
    }

    init(perspectiveFovY fovY: Float, aspect: Float, near: Float, far: Float) {
        let yScale = 1 / tan(fovY * 0.5)
        let xScale = yScale / aspect
        let zRange = far - near
        self.init(
            SIMD4(xScale, 0, 0, 0),
            SIMD4(0, yScale, 0, 0),
            SIMD4(0, 0, far / zRange, 1),
            SIMD4(0, 0, -far * near / zRange, 0)
        )
    }
}
