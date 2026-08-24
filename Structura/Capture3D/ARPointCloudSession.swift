import ARKit
import CoreVideo
import UIKit

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

    /// Fixed at `start()` and reused per-frame from a background queue —
    /// reading `UIScreen`/orientation live on every frame would touch
    /// main-thread-affined UIKit state from `processingQueue`.
    private var viewportSize = CGSize(width: 390, height: 844)
    private var interfaceOrientation: UIInterfaceOrientation = .portrait

    var onFrame: ((PointCloudFrame) -> Void)?
    var onTrackingState: ((ARCamera.TrackingState) -> Void)?
    var onFailure: ((String) -> Void)?

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
    }

    override init() {
        super.init()
        session.delegateQueue = processingQueue
        session.delegate = self
    }

    func start(viewportSize: CGSize, interfaceOrientation: UIInterfaceOrientation) {
        self.viewportSize = viewportSize
        self.interfaceOrientation = interfaceOrientation
        guard Self.isSupported else {
            onFailure?("Este dispositivo no soporta Pro Scan.")
            return
        }

        // RoomPlan's own ARSession may still be releasing the camera at the
        // exact moment this second pass starts (its `stop()` call is not
        // guaranteed to have finished tearing down hardware synchronously).
        // A short grace period avoids racing that teardown.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let configuration = ARWorldTrackingConfiguration()
            configuration.sceneReconstruction = .meshWithClassification
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                configuration.frameSemantics.insert(.sceneDepth)
            }
            self.session.run(configuration)
        }
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

        // Guard defensively rather than trust that the confidence map always
        // matches the depth map's dimensions: an out-of-bounds read here
        // would be undefined behavior, not a recoverable Swift error.
        var confidenceBuffer: UnsafePointer<UInt8>?
        var confidenceBytesPerRow = 0
        var confidenceWidth = 0
        var confidenceHeight = 0
        if let confidenceMap, let base = CVPixelBufferGetBaseAddress(confidenceMap) {
            confidenceBuffer = UnsafePointer(base.assumingMemoryBound(to: UInt8.self))
            confidenceBytesPerRow = CVPixelBufferGetBytesPerRow(confidenceMap)
            confidenceWidth = CVPixelBufferGetWidth(confidenceMap)
            confidenceHeight = CVPixelBufferGetHeight(confidenceMap)
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
            let confidenceRowInBounds = confidenceBuffer != nil && y < confidenceHeight
            let confidenceRow = confidenceRowInBounds ? confidenceBuffer.map { $0 + y * confidenceBytesPerRow } : nil
            var x = 0
            while x < width {
                let depth = depthRow[x]
                guard depth.isFinite, depth > 0 else { x += pixelStride; continue }

                let confidenceRaw: Float
                if let confidenceRow, x < confidenceWidth {
                    confidenceRaw = Float(confidenceRow[x])
                } else {
                    confidenceRaw = Float(ARConfidenceLevel.high.rawValue)
                }
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

        let viewMatrix = frame.camera.viewMatrix(for: interfaceOrientation)
        let projectionMatrix = frame.camera.projectionMatrix(
            for: interfaceOrientation,
            viewportSize: viewportSize,
            zNear: 0.05,
            zFar: 20
        )

        let processed = PointCloudFrame(
            positions: positions,
            confidences: confidences,
            timestamp: frame.timestamp,
            viewMatrix: viewMatrix,
            projectionMatrix: projectionMatrix
        )
        onFrame?(processed)
    }
}

extension ARPointCloudSession: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        processFrame(frame)
        onTrackingState?(frame.camera.trackingState)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        onFailure?(error.localizedDescription)
    }

    func sessionWasInterrupted(_ session: ARSession) {
        onFailure?("La sesión de captura se interrumpió (llamada entrante, otra app, etc.).")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        // ARKit resets tracking after an interruption; simplest recovery is
        // to just keep receiving frames — accumulated points before the
        // interruption are already in `PointCloudStore`.
    }
}
