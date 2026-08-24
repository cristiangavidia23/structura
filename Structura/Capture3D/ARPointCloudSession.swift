import ARKit
import CoreVideo

/// Raw ARKit second pass ("Pro Scan"): runs only after RoomPlan's
/// `RoomCaptureSession` has fully stopped, since ARKit allows a single
/// active session per process. Captures dense scene-depth points with
/// per-point confidence for the Metal heatmap and point-cloud export.
final class ARPointCloudSession: NSObject {
    private let session = ARSession()
    private let processingQueue = DispatchQueue(label: "com.structura.arpointcloud.processing", qos: .userInitiated)

    /// Every pixel would be far more data than needed for a live heatmap or
    /// a reasonably sized export; sample a coarse grid instead.
    private let pixelStride = 8

    var onFrame: ((PointCloudFrame) -> Void)?
    var onTrackingState: ((ARCamera.TrackingState) -> Void)?

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
    }

    override init() {
        super.init()
        session.delegateQueue = processingQueue
        session.delegate = self
    }

    func start() {
        guard Self.isSupported else { return }
        let configuration = ARWorldTrackingConfiguration()
        configuration.sceneReconstruction = .meshWithClassification
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        session.run(configuration)
    }

    func stop() {
        session.pause()
    }

    /// Unprojects the depth map into world-space points using that frame's
    /// camera intrinsics/transform, keyed against the confidence map.
    /// Runs entirely on `processingQueue`; the source `ARFrame` is never
    /// retained past this call, per ARKit's buffer-recycling contract.
    private func processFrame(_ frame: ARFrame) {
        guard let sceneDepth = frame.sceneDepth else { return }
        let depthMap = sceneDepth.depthMap
        let confidenceMap = sceneDepth.confidenceMap

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        if let confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        }
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            if let confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            }
        }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return }
        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let depthBuffer = depthBase.assumingMemoryBound(to: Float32.self)

        var confidenceBuffer: UnsafePointer<UInt8>?
        var confidenceBytesPerRow = 0
        if let confidenceMap, let base = CVPixelBufferGetBaseAddress(confidenceMap) {
            confidenceBuffer = UnsafePointer(base.assumingMemoryBound(to: UInt8.self))
            confidenceBytesPerRow = CVPixelBufferGetBytesPerRow(confidenceMap)
        }

        let intrinsics = frame.camera.intrinsics
        let cameraTransform = frame.camera.transform
        let fx = intrinsics[0][0], fy = intrinsics[1][1]
        let cx = intrinsics[2][0], cy = intrinsics[2][1]

        var positions: [SIMD3<Float>] = []
        var confidences: [Float] = []
        positions.reserveCapacity((width / pixelStride) * (height / pixelStride))
        confidences.reserveCapacity(positions.capacity)

        var y = 0
        while y < height {
            let depthRow = depthBuffer.advanced(by: (y * depthBytesPerRow) / MemoryLayout<Float32>.size)
            let confidenceRow = confidenceBuffer.map { $0 + y * confidenceBytesPerRow }
            var x = 0
            while x < width {
                let depth = depthRow[x]
                guard depth.isFinite, depth > 0 else { x += pixelStride; continue }

                let confidenceRaw = confidenceRow.map { Float($0[x]) } ?? Float(ARConfidenceLevel.high.rawValue)
                let confidence = confidenceRaw / Float(ARConfidenceLevel.high.rawValue)

                // Unproject the pixel via the camera's pinhole model, then
                // transform from camera space into world space.
                let px = (Float(x) - cx) * depth / fx
                let py = (Float(y) - cy) * depth / fy
                let cameraPoint = SIMD4<Float>(px, py, -depth, 1)
                let worldPoint = cameraTransform * cameraPoint

                positions.append(SIMD3<Float>(worldPoint.x, worldPoint.y, worldPoint.z))
                confidences.append(confidence)

                x += pixelStride
            }
            y += pixelStride
        }

        let processed = PointCloudFrame(positions: positions, confidences: confidences, timestamp: frame.timestamp)
        onFrame?(processed)
    }
}

extension ARPointCloudSession: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        processFrame(frame)
        onTrackingState?(frame.camera.trackingState)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        // Best-effort second pass: surface nothing disruptive, tracking
        // state simply stops updating and the HUD reflects that.
    }
}
