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
    /// Fires `true` right when an interruption breaks the coordinate frame,
    /// and `false` once `ProScanConfig.relocalizationConfirmationFrameCount`
    /// consecutive `.normal`-tracking frames have restored confidence in
    /// it — lets the UI show "reubicando…" instead of implying the scan is
    /// silently fine again the instant ARKit says `.normal`.
    var onCoordinateFrameBrokenStateChanged: ((Bool) -> Void)?

    /// Set on `sessionWasInterrupted`, cleared only after sustained
    /// `.normal` tracking post-interruption (see `didUpdate frame:`) — a
    /// vanilla `ARSession` (no `ARWorldMap` to relocalize against) gives no
    /// hard guarantee the coordinate origin didn't shift across an
    /// interruption, so both capture pipelines below refuse to accumulate
    /// while this is true rather than silently mixing two coordinate
    /// frames into one point cloud.
    private var isCoordinateFrameBroken = false
    private var relocalizationConfirmation = RelocalizationConfirmation()

    /// Points sourced from ARKit's own fused mesh reconstruction
    /// (`ARMeshAnchor`) rather than raw per-frame depth — ARKit builds this
    /// by integrating many frames into a voxel volume over time, so it's
    /// meaningfully more stable than any single frame's depth map. This is
    /// what export/`PointCloudSceneView` use; the live heatmap overlay
    /// during capture still uses the raw per-frame `onFrame` pipeline
    /// above, where instantaneous per-frame quality is the actual signal.
    private let meshLock = NSLock()

    /// Per-anchor storage is still needed (ARKit replaces/removes anchors
    /// individually as it re-triangulates, and each event must correctly
    /// supersede or drop exactly that anchor's prior contribution) — but
    /// this is no longer the final exported point set. `currentMeshPoints()`
    /// below feeds every stored sample, across every anchor, through a
    /// fresh `VoxelAccumulator` each time it's called, so two neighboring
    /// anchors' near-duplicate boundary vertices get fused into one real
    /// point instead of just being concatenated — replacing the previous
    /// `flatMap`, which kept every one of them (see the Pro Scan audit's
    /// finding on this). Rebuilding fresh per call (rather than feeding one
    /// long-lived accumulator incrementally) is deliberate: an incrementally
    /// fed accumulator would double-count a chunk's earlier vertices
    /// forever once ARKit re-triangulates it, since it has no notion of
    /// "this observation superseded that one" the way per-anchor storage
    /// does.
    private var meshPointsByAnchor: [UUID: [VoxelAccumulator.Sample]] = [:]

    /// Kept in lockstep with `meshPointsByAnchor` (every mutation below
    /// updates both under the same lock) so the coordinator's once-a-second
    /// HUD poll doesn't have to copy every point in the scan just to count
    /// them — that was an O(N) copy-and-discard every second, and a real
    /// contributor to delegate-queue backlog on large scans (see the Pro
    /// Scan audit). This is the *raw*, pre-fusion count — a reasonable
    /// live-progress proxy, even though the actual exported count (after
    /// `currentMeshPoints()` fuses duplicates) will typically be lower.
    private var meshPointCountTotal = 0

    /// Real per-point confidence for the fused mesh, sourced from the raw
    /// depth pipeline's observations rather than a fabricated constant —
    /// see `processMeshAnchor`.
    private let confidenceGrid = ConfidenceGrid()

    /// Throttle state for the raw per-frame depth pipeline — see
    /// `ProScanConfig.depthSampleHz`. `ARFrame.timestamp` is monotonic
    /// within a session, so a simple elapsed-time comparison is enough;
    /// only ever read/written from `processingQueue`'s serial delegate
    /// callbacks, so no lock is needed.
    private var lastProcessedFrameTimestamp: TimeInterval?

    func currentMeshPoints() -> [PointCloudExportPoint] {
        meshLock.lock()
        let samples = meshPointsByAnchor.values.flatMap { $0 }
        meshLock.unlock()

        let accumulator = VoxelAccumulator()
        for sample in samples {
            accumulator.record(sample)
        }
        return accumulator.fusedSamples().map { sample in
            PointCloudExportPoint(
                position: sample.position,
                confidence: sample.confidence,
                color: sample.color,
                normal: sample.normal,
                classification: PointCloudMeshClassification(rawValue: sample.classificationRawValue) ?? .none
            )
        }
    }

    /// O(1) *raw* (pre-fusion) point count for polling (e.g. a
    /// once-a-second HUD update) — use this instead of building the fused
    /// export set just to count it.
    func currentMeshPointCount() -> Int {
        meshLock.lock()
        defer { meshLock.unlock() }
        return meshPointCountTotal
    }

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
        resetPipelineState()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let configuration = ARWorldTrackingConfiguration()
            configuration.sceneReconstruction = .meshWithClassification

            // Explicit rather than relying on ARKit's own default (which is
            // already `.gravity`): engineering measurements need the Y axis
            // plumb, never tied to wherever the camera happened to be
            // pointed when tracking started (`.camera` alignment).
            configuration.worldAlignment = .gravity

            // Request both the raw and temporally-smoothed depth semantics.
            // `processFrame` prefers `smoothedSceneDepth`, falling back to
            // `sceneDepth` (e.g. on the first few frames, before the
            // temporal filter has enough history) — that fallback only
            // means anything if both semantics are actually requested here.
            // Previously only `.sceneDepth` was requested, so
            // `smoothedSceneDepth` was always nil and the fallback did
            // nothing on every single frame.
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                configuration.frameSemantics.insert(.smoothedSceneDepth)
            }
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                configuration.frameSemantics.insert(.sceneDepth)
            }

            // A fresh pass: reset tracking and drop any anchors that might
            // otherwise carry over, rather than implicitly inheriting
            // RoomPlan's just-torn-down session state.
            self.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        }
    }

    func stop() {
        session.pause()
    }

    private func resetPipelineState() {
        meshLock.lock()
        meshPointsByAnchor.removeAll(keepingCapacity: false)
        meshPointCountTotal = 0
        meshLock.unlock()
        confidenceGrid.reset()
        lastProcessedFrameTimestamp = nil
        isCoordinateFrameBroken = false
        relocalizationConfirmation.reset()
    }

    /// Extracts a mesh chunk's vertices (already in the anchor's local
    /// space, fused/smoothed by ARKit) into world space, sampling real
    /// camera color, real per-vertex normals, and a per-vertex classification
    /// (majority-voted from ARKit's per-*face* classification) for each.
    /// Replaces this anchor's previous point set wholesale — ARKit
    /// periodically re-triangulates a chunk as it refines, so stale
    /// vertices from an earlier version of the same chunk shouldn't linger
    /// alongside it. (Cross-anchor deduplication — two neighboring anchors'
    /// near-duplicate boundary vertices — happens later, in
    /// `currentMeshPoints()`'s `VoxelAccumulator` pass, not here.)
    ///
    /// Coordinate systems: `anchor.transform`/`frame.camera.transform` are
    /// ARKit world/camera space — right-handed, +Y up, camera looking down
    /// -Z. `CameraUnprojection.project` reprojects a camera-space point
    /// back onto the image plane (origin top-left, +Y down) to sample
    /// color; see that type's doc comment for the sign convention this
    /// depends on. Normals transform by the anchor's rotation only (a `w`
    /// component of `0`, not `1`, in the homogeneous multiply below) —
    /// translation doesn't apply to a direction.
    private func processMeshAnchor(_ anchor: ARMeshAnchor, frame: ARFrame) {
        let colorImage = frame.capturedImage
        CVPixelBufferLockBaseAddress(colorImage, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(colorImage, .readOnly) }

        let lumaBase = CVPixelBufferGetBaseAddressOfPlane(colorImage, 0)
        let lumaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(colorImage, 0)
        let lumaWidth = CVPixelBufferGetWidthOfPlane(colorImage, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(colorImage, 0)
        let chromaBase = CVPixelBufferGetBaseAddressOfPlane(colorImage, 1)
        let chromaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(colorImage, 1)

        let intrinsics = CameraUnprojection.Intrinsics(frame.camera.intrinsics)
        let imageResolution = frame.camera.imageResolution
        let colorScaleX = Float(lumaWidth) / Float(imageResolution.width)
        let colorScaleY = Float(lumaHeight) / Float(imageResolution.height)

        // World -> camera space, to reproject each mesh vertex back into
        // the color image and sample what the camera actually saw there.
        let viewMatrix = frame.camera.transform.inverse
        let anchorTransform = anchor.transform

        let vertexSource = anchor.geometry.vertices
        let vertexCount = vertexSource.count
        let vertexBuffer = vertexSource.buffer.contents().advanced(by: vertexSource.offset)
        let vertexStride = vertexSource.stride

        let normalSource = anchor.geometry.normals
        let normalBuffer = normalSource.buffer.contents().advanced(by: normalSource.offset)
        let normalStride = normalSource.stride

        // Widens under thermal pressure rather than holding a fixed rate
        // regardless of device load — see `ProScanConfig.meshVertexStride`.
        let vertexSampleStride = ProScanConfig.meshVertexStride(forThermalState: ProcessInfo.processInfo.thermalState)
        let sampledVertexIndices = Swift.stride(from: 0, to: vertexCount, by: vertexSampleStride).map { $0 }
        let sampledVertexIndexSet = Set(sampledVertexIndices)

        // Face classification is per-*face*; propagate it to just the
        // vertex indices this update will actually sample below (see
        // `FaceClassificationVoting`, a pure/tested majority-vote — this
        // call is the ARKit-dependent glue that feeds it plain arrays).
        let vertexClassifications = Self.faceClassifications(for: anchor, sampledVertexIndices: sampledVertexIndexSet)

        var samples: [VoxelAccumulator.Sample] = []
        samples.reserveCapacity(sampledVertexIndices.count)

        for vertexIndex in sampledVertexIndices {
            let localVertex = vertexBuffer
                .advanced(by: vertexIndex * vertexStride)
                .assumingMemoryBound(to: SIMD3<Float>.self)
                .pointee
            let localNormal = normalBuffer
                .advanced(by: vertexIndex * normalStride)
                .assumingMemoryBound(to: SIMD3<Float>.self)
                .pointee

            let world4 = anchorTransform * SIMD4<Float>(localVertex, 1)
            let worldVertex = SIMD3<Float>(world4.x, world4.y, world4.z)
            let worldNormal4 = anchorTransform * SIMD4<Float>(localNormal, 0)
            let worldNormalRaw = SIMD3<Float>(worldNormal4.x, worldNormal4.y, worldNormal4.z)
            let normalLength = simd_length(worldNormalRaw)
            let worldNormal = normalLength > 0 ? worldNormalRaw / normalLength : SIMD3<Float>(0, 1, 0)

            let camera4 = viewMatrix * SIMD4<Float>(worldVertex, 1)
            let cameraPoint = SIMD3<Float>(camera4.x, camera4.y, camera4.z)

            // Same LiDAR-reliable range as the raw depth pipeline below —
            // a vertex being reprojected from too far or too close in
            // *this* observing frame is the same physical unreliability
            // concern regardless of which pipeline produced it.
            let depth = -cameraPoint.z
            guard ProScanConfig.isDepthValid(depth) else { continue }

            guard let imagePixel = CameraUnprojection.project(cameraSpacePoint: cameraPoint, intrinsics: intrinsics) else {
                continue // behind the camera this frame
            }
            let colorX = Int((imagePixel.x * colorScaleX).rounded())
            let colorY = Int((imagePixel.y * colorScaleY).rounded())
            guard colorX >= 0, colorX < lumaWidth, colorY >= 0, colorY < lumaHeight else {
                continue
            }

            let color = Self.sampleColor(
                lumaBase: lumaBase, lumaBytesPerRow: lumaBytesPerRow,
                chromaBase: chromaBase, chromaBytesPerRow: chromaBytesPerRow,
                x: colorX, y: colorY
            )
            // Real per-point confidence from the depth pipeline's
            // observations at this voxel, rather than a fabricated
            // constant. A voxel the depth pipeline has never sampled (the
            // fused mesh can extend slightly beyond where raw depth has
            // landed, especially right after the throttle in `processFrame`
            // skips a frame) falls back to the *minimum acceptable*
            // confidence, not the maximum — there's no real signal here,
            // so treating it as barely-acceptable is honest; treating it
            // as fully trusted would repeat the exact fabrication this
            // fixes.
            let confidence = confidenceGrid.confidence(at: worldVertex) ?? ProScanConfig.minimumNormalizedConfidence
            let classificationRawValue = vertexClassifications[vertexIndex] ?? PointCloudMeshClassification.none.rawValue

            samples.append(VoxelAccumulator.Sample(
                position: worldVertex,
                confidence: confidence,
                color: color,
                normal: worldNormal,
                classificationRawValue: classificationRawValue
            ))
        }

        meshLock.lock()
        let previousCount = meshPointsByAnchor[anchor.identifier]?.count ?? 0
        meshPointsByAnchor[anchor.identifier] = samples
        meshPointCountTotal += samples.count - previousCount
        meshLock.unlock()
    }

    /// Reads ARKit's per-face classification and triangle-index data (both
    /// raw ARKit/Metal types) and converts them to the plain arrays
    /// `FaceClassificationVoting` operates on — the majority-vote math
    /// itself is pure and unit-tested separately; this is only the
    /// ARKit-dependent glue that feeds it.
    private static func faceClassifications(for anchor: ARMeshAnchor, sampledVertexIndices: Set<Int>) -> [Int: UInt8] {
        guard let classificationSource = anchor.geometry.classification else { return [:] }
        // Defensive: the classification source's byte layout isn't fixed
        // by the ARKit header itself (only documented, in Apple's own
        // sample code, as one `uchar` per face) — verify at runtime rather
        // than assume, and degrade to "no classification data" rather than
        // misinterpret the buffer.
        guard classificationSource.format == .uchar, classificationSource.componentsPerVector == 1 else {
            return [:]
        }

        let faces = anchor.geometry.faces
        guard faces.primitiveType == .triangle, faces.indexCountPerPrimitive == 3 else { return [:] }

        let faceBuffer = faces.buffer.contents()
        let classificationBuffer = classificationSource.buffer.contents().advanced(by: classificationSource.offset)
        let bytesPerIndex = faces.bytesPerIndex

        func vertexIndex(ofFace face: Int, corner: Int) -> Int {
            let byteOffset = (face * 3 + corner) * bytesPerIndex
            if bytesPerIndex == 2 {
                return Int(faceBuffer.loadUnaligned(fromByteOffset: byteOffset, as: UInt16.self))
            }
            return Int(faceBuffer.loadUnaligned(fromByteOffset: byteOffset, as: UInt32.self))
        }

        var faceVertexIndices: [(Int, Int, Int)] = []
        var faceClassificationRawValues: [UInt8] = []
        faceVertexIndices.reserveCapacity(faces.count)
        faceClassificationRawValues.reserveCapacity(faces.count)

        for face in 0..<faces.count {
            faceVertexIndices.append((
                vertexIndex(ofFace: face, corner: 0),
                vertexIndex(ofFace: face, corner: 1),
                vertexIndex(ofFace: face, corner: 2)
            ))
            let classificationByte = classificationBuffer
                .advanced(by: face * classificationSource.stride)
                .assumingMemoryBound(to: UInt8.self)
                .pointee
            faceClassificationRawValues.append(classificationByte)
        }

        return FaceClassificationVoting.majorityClassifications(
            faceVertexIndices: faceVertexIndices,
            faceClassificationRawValues: faceClassificationRawValues,
            sampledVertexIndices: sampledVertexIndices
        )
    }

    /// Unprojects the depth map into world-space points using that frame's
    /// camera intrinsics/transform, keyed against the confidence map.
    /// Runs entirely on `processingQueue`; the source `ARFrame` is never
    /// retained past this call, per ARKit's buffer-recycling contract.
    ///
    /// Coordinate systems: ARKit's camera/world space is right-handed, +Y
    /// up, camera looking down -Z (`ARFrame`/`ARCamera`, Apple's documented
    /// convention). `camera.intrinsics` is calibrated against image-space
    /// pixels (origin top-left, +Y down) — see `CameraUnprojection`'s doc
    /// comment for how the two conventions are reconciled.
    private func processFrame(_ frame: ARFrame) {
        // A frame whose own pose estimate ARKit doesn't trust yet
        // (`.limited`/`.notAvailable`) would unproject every point in it
        // against an unreliable transform, indistinguishably from a good
        // sample — reject the whole frame rather than let that in
        // silently. `onTrackingState?` still fires unconditionally from
        // the delegate callback below, so the live HUD status is
        // unaffected by this gate.
        guard FrameGate.isTrackingReliable(frame.camera.trackingState) else { return }
        // Same reasoning as `updateMeshAnchors`'s equivalent guard: refuse
        // to accumulate until sustained tracking has confirmed the
        // coordinate frame survived a recent interruption intact.
        guard !isCoordinateFrameBroken else { return }

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
        let intrinsics = CameraUnprojection.rescale(
            CameraUnprojection.Intrinsics(frame.camera.intrinsics),
            from: frame.camera.imageResolution,
            to: CGSize(width: width, height: height)
        )
        let cameraTransform = frame.camera.transform

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
                guard ProScanConfig.isDepthValid(depth) else { x += pixelStride; continue }

                let confidenceRaw: Float
                if let confidenceRow, x < confidenceWidth {
                    confidenceRaw = Float(confidenceRow[x])
                } else {
                    // No confidence data for this pixel at all (not merely
                    // low-confidence) — assume the best case rather than
                    // discarding a real depth reading over missing metadata.
                    confidenceRaw = Float(ProScanConfig.maximumConfidenceRawLevel)
                }
                let confidence = ProScanConfig.normalizedConfidence(fromRaw: confidenceRaw)
                guard ProScanConfig.isConfidenceAcceptable(confidence) else { x += pixelStride; continue }

                // Unproject the pixel via the camera's pinhole model, then
                // transform from camera space into world space.
                let cameraPoint = CameraUnprojection.unproject(pixel: SIMD2<Float>(Float(x), Float(y)), depth: depth, intrinsics: intrinsics)
                let worldPoint = cameraTransform * SIMD4<Float>(cameraPoint, 1)
                confidenceGrid.record(position: SIMD3<Float>(worldPoint.x, worldPoint.y, worldPoint.z), confidence: confidence)

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
        updateCoordinateFrameRecoveryState(for: frame.camera.trackingState)

        // ARKit delivers frames at up to 60 Hz; running the full depth
        // unprojection loop that often is unnecessary once the fused mesh
        // (not this pipeline) is the actual export source, and was
        // identified in the Pro Scan audit as a real contributor to
        // delegate-queue backlog. Throttle to `ProScanConfig.depthSampleHz`
        // — still frequent enough for the confidence/coverage signal this
        // pipeline now feeds into `ConfidenceGrid`.
        let minimumInterval = 1.0 / ProScanConfig.depthSampleHz
        let elapsed = lastProcessedFrameTimestamp.map { frame.timestamp - $0 }
        if elapsed == nil || elapsed! >= minimumInterval {
            lastProcessedFrameTimestamp = frame.timestamp
            processFrame(frame)
        }
        // Unconditional regardless of the throttle above: the live HUD
        // tracking-state indicator should update every frame, not just the
        // ones this pipeline actually processes.
        onTrackingState?(frame.camera.trackingState)
    }

    /// Advances the post-interruption recovery state machine: once
    /// `isCoordinateFrameBroken` is set (by `sessionWasInterrupted`), this
    /// requires `ProScanConfig.relocalizationConfirmationFrameCount`
    /// *consecutive* `.normal`-tracking frames — any non-`.normal` frame in
    /// between resets the count to zero — before trusting the frame again.
    /// Runs every frame regardless of the depth-pipeline throttle, since
    /// it's O(1) and the mesh pipeline (event-driven, not throttled) needs
    /// up-to-date state too.
    private func updateCoordinateFrameRecoveryState(for trackingState: ARCamera.TrackingState) {
        guard isCoordinateFrameBroken else { return }

        let confirmed = relocalizationConfirmation.observe(
            isReliable: FrameGate.isTrackingReliable(trackingState),
            requiredConsecutiveFrames: ProScanConfig.relocalizationConfirmationFrameCount
        )
        if confirmed {
            isCoordinateFrameBroken = false
            onCoordinateFrameBrokenStateChanged?(false)
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        updateMeshAnchors(anchors, session: session)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        updateMeshAnchors(anchors, session: session)
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        guard anchors.contains(where: { $0 is ARMeshAnchor }) else { return }
        meshLock.lock()
        for anchor in anchors {
            if let removed = meshPointsByAnchor.removeValue(forKey: anchor.identifier) {
                meshPointCountTotal -= removed.count
            }
        }
        meshLock.unlock()
    }

    private func updateMeshAnchors(_ anchors: [ARAnchor], session: ARSession) {
        guard let frame = session.currentFrame else { return }
        // Same reasoning as `processFrame`'s tracking-state gate: a mesh
        // chunk reprojected using this frame's camera transform inherits
        // whatever unreliability that transform has.
        guard FrameGate.isTrackingReliable(frame.camera.trackingState) else { return }
        // Refuse to accumulate while an interruption may have shifted the
        // coordinate origin and sustained `.normal` tracking hasn't yet
        // confirmed it's safe again — see `isCoordinateFrameBroken`.
        guard !isCoordinateFrameBroken else { return }
        // A fixed, conservative ceiling on total accumulated points — see
        // `ProScanConfig.maximumMeshPointBudget`. Existing data is kept
        // as-is (never discarded); only *further* ingestion stops, so a
        // very large or very long scan degrades gracefully instead of
        // growing memory use without bound.
        guard !ProScanConfig.isMeshPointBudgetExceeded(currentCount: currentMeshPointCount()) else { return }
        for anchor in anchors {
            guard let meshAnchor = anchor as? ARMeshAnchor else { continue }
            processMeshAnchor(meshAnchor, frame: frame)
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        onFailure?(error.localizedDescription)
    }

    func sessionWasInterrupted(_ session: ARSession) {
        onFailure?("La sesión de captura se interrumpió (llamada entrante, otra app, etc.).")
        // Stop trusting the coordinate frame immediately — points already
        // accumulated stay exactly as they are (never discarded), but
        // nothing new is added until sustained `.normal` tracking confirms
        // it's safe again (see `updateCoordinateFrameRecoveryState`).
        isCoordinateFrameBroken = true
        relocalizationConfirmation.reset()
        onCoordinateFrameBrokenStateChanged?(true)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        // No immediate action: `isCoordinateFrameBroken` stays `true` until
        // `didUpdate frame:` observes enough consecutive `.normal` frames.
        // ARKit typically resumes tracking in the same coordinate frame on
        // its own after a brief interruption, but a vanilla `ARSession`
        // (without an `ARWorldMap` to relocalize against) gives no hard
        // guarantee of that — trusting the very next frame unconditionally
        // is exactly the bug this phase fixes.
    }
}
