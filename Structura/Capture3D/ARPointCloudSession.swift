import ARKit
import CoreVideo
import UIKit

/// Raw ARKit second pass ("Pro Scan"): runs only after RoomPlan's
/// `RoomCaptureSession` has fully stopped, since ARKit allows a single
/// active session per process. Captures dense scene-depth points with
/// per-point confidence for the Metal heatmap and point-cloud export.
final class ARPointCloudSession: NSObject {
    let session = ARSession()
    private let processingQueue = DispatchQueue(label: "com.structura.arpointcloud.processing", qos: .userInitiated)

    /// Every pixel would be far more data than needed for a live heatmap or
    /// a reasonably sized export; sample a coarse grid instead.
    private let pixelStride = 5

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
        // Temporally filtered depth is noticeably less noisy per-point than
        // the raw current-frame depth — doesn't fix session-level tracking
        // drift, but does reduce point-level jitter within a single pass.
        guard let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }
        let depthMap = sceneDepth.depthMap
        let confidenceMap = sceneDepth.confidenceMap
        let colorImage = frame.capturedImage

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        if let confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        }
        CVPixelBufferLockBaseAddress(colorImage, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            if let confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            }
            CVPixelBufferUnlockBaseAddress(colorImage, .readOnly)
        }

        // `capturedImage` is biplanar 4:2:0 YCbCr (full range): plane 0 is
        // full-resolution luma, plane 1 is half-resolution interleaved
        // Cb/Cr. Sampled per point below via `sampleColor`.
        let lumaBase = CVPixelBufferGetBaseAddressOfPlane(colorImage, 0)
        let lumaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(colorImage, 0)
        let lumaWidth = CVPixelBufferGetWidthOfPlane(colorImage, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(colorImage, 0)
        let chromaBase = CVPixelBufferGetBaseAddressOfPlane(colorImage, 1)
        let chromaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(colorImage, 1)

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

        // `camera.intrinsics` is calibrated for the full camera image
        // resolution (~1920x1440), not the depth map's much smaller
        // resolution (~256x192) — using it unscaled against depth-map pixel
        // coordinates puts the optical center miles off and throws every
        // unprojected point far outside the view frustum. Scale fx/fy/cx/cy
        // down to the depth map's resolution first.
        let intrinsics = frame.camera.intrinsics
        let cameraTransform = frame.camera.transform
        let imageResolution = frame.camera.imageResolution
        let scaleX = Float(width) / Float(imageResolution.width)
        let scaleY = Float(height) / Float(imageResolution.height)
        let fx = intrinsics[0][0] * scaleX, fy = intrinsics[1][1] * scaleY
        let cx = intrinsics[2][0] * scaleX, cy = intrinsics[2][1] * scaleY

        // Maps a depth-map pixel to its matching pixel in the full-resolution
        // color image, to sample the real camera color for that point.
        let colorScaleX = Float(lumaWidth) / Float(width)
        let colorScaleY = Float(lumaHeight) / Float(height)

        var positions: [SIMD3<Float>] = []
        var confidences: [Float] = []
        var colors: [SIMD3<Float>] = []
        positions.reserveCapacity((width / pixelStride) * (height / pixelStride))
        confidences.reserveCapacity(positions.capacity)
        colors.reserveCapacity(positions.capacity)

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

                let colorX = min(max(Int(Float(x) * colorScaleX), 0), lumaWidth - 1)
                let colorY = min(max(Int(Float(y) * colorScaleY), 0), lumaHeight - 1)
                let color = Self.sampleColor(
                    lumaBase: lumaBase, lumaBytesPerRow: lumaBytesPerRow,
                    chromaBase: chromaBase, chromaBytesPerRow: chromaBytesPerRow,
                    x: colorX, y: colorY
                )

                positions.append(SIMD3<Float>(worldPoint.x, worldPoint.y, worldPoint.z))
                confidences.append(confidence)
                colors.append(color)

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
            colors: colors,
            timestamp: frame.timestamp,
            viewMatrix: viewMatrix,
            projectionMatrix: projectionMatrix
        )
        onFrame?(processed)
    }

    /// BT.601 full-range YCbCr → RGB, sampled at a single luma pixel (and
    /// its corresponding half-resolution chroma pixel).
    private static func sampleColor(
        lumaBase: UnsafeMutableRawPointer?,
        lumaBytesPerRow: Int,
        chromaBase: UnsafeMutableRawPointer?,
        chromaBytesPerRow: Int,
        x: Int,
        y: Int
    ) -> SIMD3<Float> {
        guard let lumaBase, let chromaBase else { return SIMD3<Float>(0.5, 0.5, 0.5) }

        let luma = lumaBase.load(fromByteOffset: y * lumaBytesPerRow + x, as: UInt8.self)
        let chromaX = (x / 2) * 2
        let chromaY = y / 2
        let chromaOffset = chromaY * chromaBytesPerRow + chromaX
        let cb = chromaBase.load(fromByteOffset: chromaOffset, as: UInt8.self)
        let cr = chromaBase.load(fromByteOffset: chromaOffset + 1, as: UInt8.self)

        let yVal = Float(luma)
        let cbVal = Float(cb) - 128
        let crVal = Float(cr) - 128

        let r = yVal + 1.402 * crVal
        let g = yVal - 0.344136 * cbVal - 0.714136 * crVal
        let b = yVal + 1.772 * cbVal

        return SIMD3<Float>(
            min(max(r / 255, 0), 1),
            min(max(g / 255, 0), 1),
            min(max(b / 255, 0), 1)
        )
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
