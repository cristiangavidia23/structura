import ARKit
import CoreVideo
import UIKit
import os
import QuartzCore

/// Raw ARKit second pass ("Pro Scan"): runs only after RoomPlan's
/// `RoomCaptureSession` has fully stopped, since ARKit allows a single
/// active session per process. Captures dense scene-depth points with
/// per-point confidence for the Metal heatmap and point-cloud export.
/// `@unchecked Sendable`: every mutable stored property this type exposes
/// (`meshPointsByAnchor`, `fusedAccumulator`, `meshPointCountTotal`) is only
/// ever touched under `meshLock`, and `currentMeshPoints`/
/// `currentMeshPointCount` acquire it themselves — so a call from any
/// thread or actor is genuinely safe, not merely assumed safe. This is what
/// lets `ProScanCoordinator.currentMeshPointsSnapshot(authoritative:)`
/// below read the fused point set without hopping onto the main actor
/// (audit finding C1's remaining piece: the *read* itself, now that the
/// read is cheap). `@unchecked` because the compiler cannot verify a
/// hand-rolled lock the way it verifies an `actor`; the project's Fase 5
/// strict-concurrency migration should revisit whether this can become a
/// real `actor` instead.
final class ARPointCloudSession: NSObject, @unchecked Sendable {
    let session = ARSession()

    /// ARSession's own delegate callback queue — kept deliberately thin.
    /// Every delegate method below either does O(1) bookkeeping directly,
    /// or (for mesh-anchor events) extracts only the small, frame-scoped
    /// data `processMeshAnchor` needs and dispatches the actual per-vertex
    /// work onto `meshProcessingQueue`, returning immediately.
    ///
    /// Before this phase, `processMeshAnchor`'s full per-vertex/voxel cost
    /// ran directly on this queue, synchronously, inside the delegate
    /// callback itself. ARKit invokes every delegate method on this queue
    /// serially and expects the delegate to return promptly — a slow chunk
    /// update backed up frame delivery behind it, which is the confirmed
    /// root mechanism behind the mesh visibly freezing or fragmenting
    /// during a real scan (architecture audit finding C4). The raw-depth
    /// pipeline (`processFrame`) deliberately stays running directly on
    /// this queue rather than gaining a third queue of its own: it is
    /// already throttled to `ProScanConfig.depthSampleHz` and does a small,
    /// bounded amount of work per invocation, unlike mesh processing's
    /// unbounded-by-comparison per-chunk vertex count — see `processFrame`'s
    /// doc comment for the full reasoning and the F0 profiling this should
    /// be re-checked against.
    private let delegateQueue = DispatchQueue(label: "com.structura.arpointcloud.delegate", qos: .userInitiated)

    /// Where the expensive part of mesh-anchor processing actually runs:
    /// per-vertex color sampling, face-classification majority voting, and
    /// voxel accumulation (`processMeshAnchor`). Serial, not concurrent —
    /// this matters for correctness, not just throughput: `didAdd`/
    /// `didUpdate`/`didRemove` for the *same* anchor identifier must be
    /// applied in the order ARKit raised them, or a removal could be
    /// processed before a still-queued update for that anchor, which would
    /// then wrongly resurrect it. Every mesh-anchor delegate callback below
    /// dispatches onto this queue in the order it was invoked on the
    /// (also serial) `delegateQueue`, which is what preserves that
    /// ordering — a serial `DispatchQueue` never reorders blocks enqueued
    /// onto it.
    private let meshProcessingQueue = DispatchQueue(label: "com.structura.arpointcloud.mesh", qos: .userInitiated)

    /// Sampling every depth pixel would be far more data than a 2 cm voxel
    /// grid can even distinguish; sample a coarse grid instead. Sourced from
    /// `ProScanConfig` rather than redeclared here — this used to be a second
    /// hardcoded `5` that could drift from the documented one.
    private var pixelStride: Int {
        ProScanConfig.depthPixelStride(forThermalState: ProcessInfo.processInfo.thermalState)
    }

    /// Fixed at `start()` and reused per-frame from a background queue —
    /// reading `UIScreen`/orientation live on every frame would touch
    /// main-thread-affined UIKit state from `delegateQueue`.
    private var viewportSize = CGSize(width: 390, height: 844)
    private var interfaceOrientation: UIInterfaceOrientation = .portrait

    /// Set once by `start(viewportSize:interfaceOrientation:initialWorldMap:)`
    /// and read again by every retry `attemptStart()` performs (Fase 3,
    /// finding E6's backoff) — a world map to continue in, rather than
    /// resetting to a fresh coordinate origin, when a caller has one from a
    /// previous Pro Scan pass over the same named scan (`WorldMapStore`).
    private var initialWorldMap: ARWorldMap?

    var onFrame: ((PointCloudFrame) -> Void)?
    var onTrackingState: ((ARCamera.TrackingState) -> Void)?
    var onFailure: ((String) -> Void)?
    /// Fires `true` right when an interruption breaks the coordinate frame,
    /// and `false` once `ProScanConfig.relocalizationConfirmationFrameCount`
    /// consecutive `.normal`-tracking frames have restored confidence in
    /// it — lets the UI show "reubicando…" instead of implying the scan is
    /// silently fine again the instant ARKit says `.normal`.
    var onCoordinateFrameBrokenStateChanged: ((Bool) -> Void)?
    /// Fires at most once a second (see `metricsPublishIntervalSeconds`)
    /// with the ARKit delivery rate / delegate latency observed since the
    /// last publish — Fase 0 of the architecture audit: "sin línea base
    /// todo lo demás es opinión." Never fires more often than that
    /// regardless of ARKit's actual frame rate, on purpose — see
    /// `delegateFrameMetrics`'s doc comment on why this call site is exactly
    /// the same shape as `PointCloudStore`'s throttled publish (Fase 1,
    /// finding C5): this instrumentation must not itself become a new
    /// version of the problem Fase 1 just fixed.
    var onPerformanceSample: ((DelegateFrameMetrics.Snapshot) -> Void)?

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

    /// The fused point set, maintained **incrementally** alongside
    /// `meshPointsByAnchor` under the same `meshLock` — every mutation of
    /// one is a matching mutation of the other, so the two can never drift
    /// out of step.
    ///
    /// This replaces building a throwaway `VoxelAccumulator` from every
    /// stored sample on each call to `currentMeshPoints()`. That rebuild
    /// was O(points-in-the-entire-scan), it ran on the main actor every
    /// autosave (`ProScanCaptureView.startAutosaveLoop`), and it held
    /// `meshLock` throughout — blocking the mesh pipeline behind it. It was
    /// finding C1 of the architecture audit, and the single largest source
    /// of the frame backlog that shows up as a mesh that freezes or breaks
    /// into islands. Now a re-triangulated chunk costs only its own
    /// vertices: withdraw the anchor's previous samples, record its new
    /// ones (see `VoxelAccumulator.remove(_:)`).
    private let fusedAccumulator = VoxelAccumulator()


    /// Raw (pre-fusion) count of depth samples folded in, for the live HUD
    /// only — the same "progress proxy, not the export count" role
    /// `meshPointCountTotal` plays for the mesh path.
    private var depthSampleCountTotal = 0

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
    /// only ever read/written from `delegateQueue`'s serial delegate
    /// callbacks (`processFrame` stays on this queue — see its doc
    /// comment), so no lock is needed.
    private var lastProcessedFrameTimestamp: TimeInterval?

    /// `os_signpost` instrumentation for the three call sites Fase 0 of the
    /// architecture audit names explicitly: `processMeshAnchor`,
    /// `processFrame`, and `currentMeshPoints`. Purely additive — every
    /// interval here wraps existing work without changing it — so this can
    /// be recorded in Instruments (Time Profiler + `os_signpost` template,
    /// subsystem `com.structura.capture3d`) against a real device scan and
    /// compared before/after a pipeline change, which is the actual point:
    /// a signpost only says how long something took and how often it ran,
    /// never why, so it complements rather than replaces the FPS/latency
    /// numbers below.
    private static let signposter = OSSignposter(subsystem: "com.structura.capture3d", category: "ProScanPipeline")

    /// Real ARKit frame-delivery rate and delegate-callback latency — see
    /// `DelegateFrameMetrics`'s doc comment for why these are not the same
    /// thing `PerformanceMonitor.fps` already measures. Recorded on every
    /// single frame in `didUpdate frame:` (O(1) arithmetic, not gated by
    /// `processFrame`'s own throttle — the backlog this measures can exist
    /// independently of whether this particular frame was one `processFrame`
    /// chose to process), and published through `onPerformanceSample` at
    /// most once a second — see that property's doc comment.
    private var delegateFrameMetrics = DelegateFrameMetrics()
    private var lastMetricsPublishAt: TimeInterval = 0
    private static let metricsPublishIntervalSeconds: TimeInterval = 1.0

    /// Fase 2 of the architecture audit, finding E1 — see
    /// `AngularVelocityGate`'s doc comment for why this is a different,
    /// additional check from `FrameGate.isTrackingReliable`, not a
    /// replacement for it. Evaluated once per `didUpdate frame:` call (see
    /// `recordDelegateFrameMetrics`'s neighbor `updateAngularVelocityGate`),
    /// so both `processFrame` and `updateMeshAnchors` — which react to the
    /// same delivered frame, just via different delegate callbacks — gate
    /// on one consistent verdict instead of each keeping (and disagreeing
    /// about) its own frame-to-frame comparison.
    private var angularVelocityGate = AngularVelocityGate()
    private var isCurrentFrameMotionAcceptable = true

    /// Fase 3 of the architecture audit, finding E4 — see `ScanDriftBudget`'s
    /// doc comment for why this replaces a flat elapsed-time cutoff.
    /// Updated on every `didUpdate frame:` call, off the main actor, same
    /// cost class as `angularVelocityGate`'s own per-frame update.
    private var driftBudget = ScanDriftBudget()
    private var hasNotifiedDriftBudgetExceeded = false
    /// Fires once (edge-triggered, like `onCoordinateFrameBrokenStateChanged`)
    /// the first time `driftBudget.isExhausted` becomes true for this pass.
    var onDriftBudgetExceeded: (() -> Void)?

    /// Fase 3, finding E6 — see `ARSessionStartupPolicy`. `startupAttemptCount`
    /// and `lastRunAttemptTimestamp` track the in-flight startup retry state
    /// machine; `isActive` guards a still-scheduled retry from calling
    /// `session.run()` again after the user has already backed out via
    /// `stop()`.
    private var startupAttemptCount = 0
    private var lastRunAttemptTimestamp: TimeInterval = 0
    private var isActive = false

    /// The fused, deduplicated point set to export or visualize.
    ///
    /// - Parameter authoritative: whether the result is returned in a
    ///   deterministic order. `true` at the final export, where a stable
    ///   point order is what makes two runs of the same scan diffable;
    ///   `false` (the default) on the autosave timer, which overwrites the
    ///   same crash-recovery file every few seconds and whose order nothing
    ///   reads — worth skipping, since sorting every occupied voxel key runs
    ///   into tens of milliseconds with `meshLock` held.
    ///
    ///   This parameter used to select a full rebuild from every stored
    ///   sample; see the note in the body for why that is gone.
    func currentMeshPoints(authoritative: Bool = false) -> [PointCloudExportPoint] {
        // Two distinct signpost names, not one with a dynamic argument, so
        // Instruments' timeline trivially separates the two read shapes
        // without needing to inspect each interval's payload.
        let signpostName: StaticString = authoritative ? "currentMeshPoints.authoritative" : "currentMeshPoints.incremental"
        let signpostID = Self.signposter.makeSignpostID()
        let signpostState = Self.signposter.beginInterval(signpostName, id: signpostID)
        defer { Self.signposter.endInterval(signpostName, signpostState) }

        // One accumulator now holds both sources — ARKit's scene mesh and
        // the LiDAR depth map — so reading the cloud is a single pass with
        // nothing to merge.
        //
        // It used to be two, fused on every read. That cost three O(voxels)
        // passes (sort, re-record, sort again) *per autosave*, most of it
        // with `meshLock` held against a depth pipeline trying to ingest
        // twelve times a second — a visible stutter every autosave tick,
        // growing with the scan.
        //
        // The authoritative rebuild that used to run here is gone with it,
        // and deliberately so. It rebuilt from `meshPointsByAnchor` to shed
        // the floating-point residue of repeated record/withdraw cycles —
        // but those raw samples only ever existed for the *mesh* path.
        // Depth samples are folded into their voxel and dropped (retaining
        // them raw would cost hundreds of megabytes), so a rebuild from that
        // store can no longer see the dense majority of the cloud: it would
        // quietly export far less than the app displays. Silently shipping a
        // sparser file than the user was shown is a much worse failure than
        // float residue in the last decimal of a weighted average.
        //
        // `authoritative` now selects a deterministic point order instead —
        // see `VoxelAccumulator.fusedSamples(sorted:)`.
        meshLock.lock()
        let fused = fusedAccumulator.fusedSamples(sorted: authoritative)
        meshLock.unlock()

        return fused.map { sample in
            PointCloudExportPoint(
                position: sample.position,
                confidence: sample.confidence,
                color: sample.color,
                normal: sample.normal,
                classification: PointCloudMeshClassification(rawValue: sample.classificationRawValue) ?? .none,
                isConfidenceObserved: sample.isConfidenceObserved
            )
        }
    }

    /// O(1) *raw* (pre-fusion) point count for polling (e.g. a
    /// once-a-second HUD update) — use this instead of building the fused
    /// export set just to count it.
    func currentMeshPointCount() -> Int {
        meshLock.lock()
        defer { meshLock.unlock() }
        // Both paths, since both end up in the exported cloud. Still the
        // raw pre-fusion total this has always reported: a live progress
        // proxy, not the (lower, de-duplicated) count the export will hold.
        return meshPointCountTotal + depthSampleCountTotal
    }

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
    }

    override init() {
        super.init()
        session.delegateQueue = delegateQueue
        session.delegate = self
    }

    func start(viewportSize: CGSize, interfaceOrientation: UIInterfaceOrientation, initialWorldMap: ARWorldMap? = nil) {
        self.viewportSize = viewportSize
        self.interfaceOrientation = interfaceOrientation
        self.initialWorldMap = initialWorldMap
        guard Self.isSupported else {
            onFailure?("Este dispositivo no soporta Pro Scan.")
            return
        }

        resetPipelineState()
        isActive = true
        // Fase 3 of the architecture audit, finding E6: no fixed grace
        // period before the first attempt — see `ARSessionStartupPolicy`'s
        // doc comment for why reacting to what ARKit actually reports
        // (`didFailWithError`, handled below) is the right replacement for
        // guessing how long RoomPlan's teardown takes.
        attemptStart()
    }

    /// One attempt to start the underlying `ARSession` — called from
    /// `start()` for the first attempt, and again by `didFailWithError`'s
    /// retry branch below for every subsequent one. Builds a fresh
    /// `ARWorldTrackingConfiguration` each time rather than caching one:
    /// cheap, and simpler than reasoning about whether a cached
    /// configuration object could be mutated or reused unsafely across
    /// attempts.
    private func attemptStart() {
        startupAttemptCount += 1
        lastRunAttemptTimestamp = CACurrentMediaTime()

        let configuration = ARWorldTrackingConfiguration()
        configuration.sceneReconstruction = .meshWithClassification

        // Explicit rather than relying on ARKit's own default (which is
        // already `.gravity`): engineering measurements need the Y axis
        // plumb, never tied to wherever the camera happened to be pointed
        // when tracking started (`.camera` alignment).
        configuration.worldAlignment = .gravity

        // Request both the raw and temporally-smoothed depth semantics.
        // `processFrame` prefers `smoothedSceneDepth`, falling back to
        // `sceneDepth` (e.g. on the first few frames, before the temporal
        // filter has enough history) — that fallback only means anything
        // if both semantics are actually requested here.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }

        // `.resetTracking` and `initialWorldMap` are mutually exclusive in
        // effect — resetting tracking discards the very coordinate frame
        // the world map exists to continue. Without one, this is a fresh
        // pass: reset tracking and drop any anchors that might otherwise
        // carry over, rather than implicitly inheriting RoomPlan's
        // just-torn-down session state (unchanged from before this world
        // map continuity was added).
        if let initialWorldMap {
            configuration.initialWorldMap = initialWorldMap
            session.run(configuration, options: [.removeExistingAnchors])
        } else {
            session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        }
    }

    func stop() {
        isActive = false
        session.pause()
    }

    /// Reads back the session's current world map for persistence
    /// (`WorldMapStore`) — must be called *before* `stop()` pauses the
    /// session; `ARSession.getCurrentWorldMap` requires an active session
    /// and its completion runs on an arbitrary queue, not necessarily the
    /// caller's. `nil` on any failure (no tracking yet, or ARKit couldn't
    /// produce one) — a best-effort capture, not something a Pro Scan
    /// finish should ever block or fail on.
    func currentWorldMap(_ completion: @escaping (ARWorldMap?) -> Void) {
        session.getCurrentWorldMap { worldMap, _ in
            completion(worldMap)
        }
    }

    /// Called synchronously from `start()`, on whatever thread called it
    /// (the coordinator calls `start()` from the main actor) — not from
    /// `delegateQueue` or `meshProcessingQueue`. `meshLock`/
    /// `confidenceGrid`'s own lock make the mutations here safe regardless
    /// of caller thread; what this does *not* guard against is a still-
    /// in-flight `meshProcessingQueue` block from a *previous* scan on this
    /// same `ARPointCloudSession` instance racing this reset. That would
    /// require `stop()` to synchronously drain both queues before
    /// returning, which it does not today — pre-existing behavior, not
    /// something this phase changes, and out of scope for audit finding
    /// C4 specifically. In practice each Pro Scan attempt gets a fresh
    /// `ProScanCoordinator`/`ARPointCloudSession`, so `start()` is not
    /// currently called more than once per instance.
    private func resetPipelineState() {
        meshLock.lock()
        meshPointsByAnchor.removeAll(keepingCapacity: false)
        fusedAccumulator.reset()
        meshPointCountTotal = 0
        depthSampleCountTotal = 0
        meshLock.unlock()
        confidenceGrid.reset()
        lastProcessedFrameTimestamp = nil
        isCoordinateFrameBroken = false
        relocalizationConfirmation.reset()
        delegateFrameMetrics.reset()
        lastMetricsPublishAt = 0
        angularVelocityGate.reset()
        isCurrentFrameMotionAcceptable = true
        driftBudget.reset()
        hasNotifiedDriftBudgetExceeded = false
        startupAttemptCount = 0
    }

    /// A frame's color image and camera parameters, copied out of a live
    /// `ARFrame` at the moment mesh-anchor processing is dispatched onto
    /// `meshProcessingQueue` — see `updateMeshAnchors`.
    ///
    /// ARKit's `ARFrame` (and the `CVPixelBuffer`s it vends, including
    /// `capturedImage`) are only guaranteed valid for the duration of the
    /// delegate callback that hands them out: they come from a small,
    /// recycled buffer pool, and holding one past that callback — even
    /// just retaining the `CVPixelBuffer` itself, let alone the `ARFrame`
    /// — can stall ARKit's own capture pipeline. `ARMeshAnchor` has no such
    /// restriction (its `.geometry` buffers stay valid for the anchor
    /// object's own lifetime), which is why only the frame's color image
    /// and camera parameters need to be copied here, not the anchor.
    private struct MeshFrameSnapshot {
        let lumaBytes: [UInt8]
        let lumaBytesPerRow: Int
        let lumaWidth: Int
        let lumaHeight: Int
        let chromaBytes: [UInt8]
        let chromaBytesPerRow: Int
        let intrinsics: CameraUnprojection.Intrinsics
        let imageResolution: CGSize
        let cameraTransform: simd_float4x4
    }

    /// Copies the one part of `frame` that mesh processing cannot safely
    /// read later — the captured color image — plus the frame's camera
    /// parameters (plain value types, copied here only for convenience).
    /// Called synchronously on `delegateQueue`, while `frame` is still
    /// guaranteed valid; the returned snapshot is then safe to read from
    /// `meshProcessingQueue` after this callback has returned.
    ///
    /// The copy itself is a bounded, fixed-size memcpy of both YCbCr
    /// planes (a few megabytes) — cheap relative to the per-vertex
    /// classification/voxel work it unblocks from running on the delegate
    /// queue, and it's what lets that work run without touching a buffer
    /// ARKit may have already recycled by the time it does.
    private static func makeMeshFrameSnapshot(from frame: ARFrame) -> MeshFrameSnapshot? {
        let colorImage = frame.capturedImage
        CVPixelBufferLockBaseAddress(colorImage, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(colorImage, .readOnly) }

        guard
            let lumaBase = CVPixelBufferGetBaseAddressOfPlane(colorImage, 0),
            let chromaBase = CVPixelBufferGetBaseAddressOfPlane(colorImage, 1)
        else { return nil }

        let lumaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(colorImage, 0)
        let lumaWidth = CVPixelBufferGetWidthOfPlane(colorImage, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(colorImage, 0)
        let chromaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(colorImage, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(colorImage, 1)

        let lumaBytes = [UInt8](UnsafeRawBufferPointer(start: lumaBase, count: lumaBytesPerRow * lumaHeight))
        let chromaBytes = [UInt8](UnsafeRawBufferPointer(start: chromaBase, count: chromaBytesPerRow * chromaHeight))

        return MeshFrameSnapshot(
            lumaBytes: lumaBytes,
            lumaBytesPerRow: lumaBytesPerRow,
            lumaWidth: lumaWidth,
            lumaHeight: lumaHeight,
            chromaBytes: chromaBytes,
            chromaBytesPerRow: chromaBytesPerRow,
            intrinsics: CameraUnprojection.Intrinsics(frame.camera.intrinsics),
            imageResolution: frame.camera.imageResolution,
            cameraTransform: frame.camera.transform
        )
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
    /// Runs on `meshProcessingQueue`, not `delegateQueue` — see that
    /// property's doc comment (architecture audit finding C4). `frame` is
    /// a `MeshFrameSnapshot`, not a live `ARFrame`, precisely because this
    /// runs after the delegate callback that received the real frame has
    /// already returned.
    ///
    /// Coordinate systems: `anchor.transform`/`frame.cameraTransform` are
    /// ARKit world/camera space — right-handed, +Y up, camera looking down
    /// -Z. `CameraUnprojection.project` reprojects a camera-space point
    /// back onto the image plane (origin top-left, +Y down) to sample
    /// color; see that type's doc comment for the sign convention this
    /// depends on. Normals transform by the anchor's rotation only (a `w`
    /// component of `0`, not `1`, in the homogeneous multiply below) —
    /// translation doesn't apply to a direction.
    private func processMeshAnchor(_ anchor: ARMeshAnchor, frame: MeshFrameSnapshot, thermalState: ProcessInfo.ThermalState) {
        // Fase 0 instrumentation: this runs on `meshProcessingQueue`, off
        // ARKit's own delegate queue since Fase 1 — the signpost interval
        // is what lets a real-device profile confirm this chunk's own
        // per-vertex cost (not just whether it's blocking frame delivery
        // anymore, which C4's fix already addresses).
        let signpostID = Self.signposter.makeSignpostID()
        let signpostState = Self.signposter.beginInterval("processMeshAnchor", id: signpostID)
        defer { Self.signposter.endInterval("processMeshAnchor", signpostState) }

        let lumaBytesPerRow = frame.lumaBytesPerRow
        let lumaWidth = frame.lumaWidth
        let lumaHeight = frame.lumaHeight
        let chromaBytesPerRow = frame.chromaBytesPerRow

        let intrinsics = frame.intrinsics
        let imageResolution = frame.imageResolution
        let colorScaleX = Float(lumaWidth) / Float(imageResolution.width)
        let colorScaleY = Float(lumaHeight) / Float(imageResolution.height)

        // World -> camera space, to reproject each mesh vertex back into
        // the color image and sample what the camera actually saw there.
        let viewMatrix = frame.cameraTransform.inverse
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
        // `thermalState` is read once per anchor-update *batch* by the
        // caller (Fase 2, finding C8), not re-read here per anchor: within
        // one `didAdd`/`didUpdate` batch — commonly several anchors at
        // once as ARKit re-triangulates a region — thermal state cannot
        // meaningfully change between the first anchor processed and the
        // last, so reading `ProcessInfo.processInfo.thermalState` (a
        // cross-process call) once per batch rather than once per anchor is
        // free correctness, not an approximation.
        let vertexSampleStride = ProScanConfig.meshVertexStride(forThermalState: thermalState)
        let sampledVertexIndices = Swift.stride(from: 0, to: vertexCount, by: vertexSampleStride).map { $0 }
        let sampledVertexIndexSet = Set(sampledVertexIndices)

        // Face classification is per-*face*; propagate it to just the
        // vertex indices this update will actually sample below (see
        // `FaceClassificationVoting`, a pure/tested majority-vote — this
        // call is the ARKit-dependent glue that feeds it plain arrays).
        let vertexClassifications = Self.faceClassifications(for: anchor, sampledVertexIndices: sampledVertexIndexSet)

        var samples: [VoxelAccumulator.Sample] = []
        samples.reserveCapacity(sampledVertexIndices.count)

        // The snapshot's color planes are plain owned `[UInt8]` arrays, not
        // a locked `CVPixelBuffer` — no lock/unlock needed here, just a
        // pointer to iterate them with. `sampleColor` takes read-only
        // `UnsafeRawPointer`s now for exactly this case (see its doc
        // comment); `processFrame`'s call site still passes it pointers
        // sourced from a locked `CVPixelBuffer`, unaffected by this change.
        frame.lumaBytes.withUnsafeBytes { lumaBuffer in
            frame.chromaBytes.withUnsafeBytes { chromaBuffer in
                let lumaBase = lumaBuffer.baseAddress
                let chromaBase = chromaBuffer.baseAddress

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
                    // so treating it as barely-acceptable is honest as a number to
                    // feed the renderer/PLY. But Fase 2 (finding E2) is precisely
                    // that a *fallback number* must never be indistinguishable from
                    // a *real* one to a downstream engineering consumer of the
                    // exported file — `observedConfidence == nil` is threaded
                    // through as `isConfidenceObserved: false` below so
                    // `LASExporter` can write an honest "no observation" sentinel
                    // instead of a value that reads as a genuine mid-confidence
                    // reading. `confidenceGrid` now has its own lock (see that
                    // type) precisely because this call and `processFrame`'s
                    // `record` below run on two different queues.
                    let observedConfidence = confidenceGrid.confidence(at: worldVertex)
                    let confidence = observedConfidence ?? ProScanConfig.minimumNormalizedConfidence
                    let classificationRawValue = vertexClassifications[vertexIndex] ?? PointCloudMeshClassification.none.rawValue

                    samples.append(VoxelAccumulator.Sample(
                        position: worldVertex,
                        confidence: confidence,
                        color: color,
                        normal: worldNormal,
                        classificationRawValue: classificationRawValue,
                        isConfidenceObserved: observedConfidence != nil
                    ))
                }
            }
        }

        // Per-anchor storage and the fused accumulator are updated together
        // under one lock: withdraw this anchor's previous contribution,
        // then record the new one. ARKit re-triangulates a chunk
        // repeatedly, so without the withdrawal an earlier version of the
        // same chunk would keep voting in the fused result forever.
        meshLock.lock()
        let previous = meshPointsByAnchor[anchor.identifier]
        if let previous {
            fusedAccumulator.remove(contentsOf: previous)
        }
        fusedAccumulator.record(contentsOf: samples)
        meshPointsByAnchor[anchor.identifier] = samples
        meshPointCountTotal += samples.count - (previous?.count ?? 0)
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
    /// Runs entirely on `delegateQueue`, unlike mesh-anchor processing —
    /// deliberately not split onto its own queue for this phase: it is
    /// already throttled to `ProScanConfig.depthSampleHz`, and its
    /// per-invocation cost (one pass over the depth map at `pixelStride`,
    /// a few thousand samples at most) is small and bounded compared to a
    /// mesh chunk's potentially much larger vertex count. If profiling
    /// (Fase 0 of the architecture audit) later shows this pipeline is
    /// still a meaningful contributor to delegate-queue latency, the same
    /// snapshot-and-dispatch pattern `updateMeshAnchors` uses below would
    /// apply here too. The source `ARFrame` is never retained past this
    /// call, per ARKit's buffer-recycling contract.
    ///
    /// Coordinate systems: ARKit's camera/world space is right-handed, +Y
    /// up, camera looking down -Z (`ARFrame`/`ARCamera`, Apple's documented
    /// convention). `camera.intrinsics` is calibrated against image-space
    /// pixels (origin top-left, +Y down) — see `CameraUnprojection`'s doc
    /// comment for how the two conventions are reconciled.
    private func processFrame(_ frame: ARFrame) {
        // Fase 0 instrumentation: this stays on `delegateQueue` by design
        // (see this method's doc comment) — the signpost interval is what
        // lets a real-device profile confirm that choice is still correct
        // rather than assume it.
        let signpostID = Self.signposter.makeSignpostID()
        let signpostState = Self.signposter.beginInterval("processFrame", id: signpostID)
        defer { Self.signposter.endInterval("processFrame", signpostState) }

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
        // Fase 2, finding E1: a frame captured mid-fast-rotation is more
        // likely to be motion-blurred even when ARKit's own tracking-state
        // label still reads as reliable — see `AngularVelocityGate`.
        guard isCurrentFrameMotionAcceptable else { return }

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
        // The same points, packaged for the accumulator. Built in this one
        // pass rather than a second one: the expensive part (unprojection,
        // color sampling) is already being paid for here.
        var depthSamples: [VoxelAccumulator.Sample] = []
        positions.reserveCapacity((width / pixelStride) * (height / pixelStride))
        confidences.reserveCapacity(positions.capacity)
        colors.reserveCapacity(positions.capacity)
        depthSamples.reserveCapacity(positions.capacity)

        // Rotation-only slice of the camera transform, for turning a
        // camera-space normal into a world-space one. A normal is a
        // direction, so it must not pick up the transform's translation.
        let cameraRotation = simd_float3x3(
            SIMD3<Float>(cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z),
            SIMD3<Float>(cameraTransform.columns.1.x, cameraTransform.columns.1.y, cameraTransform.columns.1.z),
            SIMD3<Float>(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
        )
        // Captured once per frame rather than read per pixel — `pixelStride`
        // reads `ProcessInfo.thermalState`, which is not free.
        let stride = pixelStride

        var y = 0
        while y < height {
            let depthRow = depthBuffer.advanced(by: (y * depthBytesPerRow) / MemoryLayout<Float32>.size)
            let confidenceRowInBounds = confidenceBuffer != nil && y < confidenceHeight
            let confidenceRow = confidenceRowInBounds ? confidenceBuffer.map { $0 + y * confidenceBytesPerRow } : nil
            var x = 0
            while x < width {
                let depth = depthRow[x]
                guard ProScanConfig.isDepthValid(depth) else { x += stride; continue }

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
                guard ProScanConfig.isConfidenceAcceptable(confidence) else { x += stride; continue }

                // Unproject the pixel via the camera's pinhole model, then
                // transform from camera space into world space.
                let cameraPoint = CameraUnprojection.unproject(pixel: SIMD2<Float>(Float(x), Float(y)), depth: depth, intrinsics: intrinsics)
                let worldPoint4 = cameraTransform * SIMD4<Float>(cameraPoint, 1)
                let worldPoint = SIMD3<Float>(worldPoint4.x, worldPoint4.y, worldPoint4.z)
                confidenceGrid.record(position: worldPoint, confidence: confidence)

                let colorX = min(max(Int(Float(x) * colorScaleX), 0), lumaWidth - 1)
                let colorY = min(max(Int(Float(y) * colorScaleY), 0), lumaHeight - 1)
                let color = Self.sampleColor(
                    lumaBase: lumaBase, lumaBytesPerRow: lumaBytesPerRow,
                    chromaBase: chromaBase, chromaBytesPerRow: chromaBytesPerRow,
                    x: colorX, y: colorY
                )

                positions.append(worldPoint)
                confidences.append(confidence)
                colors.append(color)

                if let cameraNormal = Self.surfaceNormal(
                    atX: x, y: y,
                    cameraPoint: cameraPoint,
                    stride: stride,
                    width: width, height: height,
                    depthBuffer: depthBuffer, depthBytesPerRow: depthBytesPerRow,
                    intrinsics: intrinsics
                ) {
                    depthSamples.append(
                        VoxelAccumulator.Sample(
                            position: worldPoint,
                            confidence: confidence,
                            color: color,
                            normal: simd_normalize(cameraRotation * cameraNormal),
                            // ARKit classifies its *mesh* faces, not depth
                            // pixels, so this point has no label to report —
                            // which is not the same as reporting "no label".
                            // See `VoxelAccumulator.unclassifiedRawValue`:
                            // passing `.none` here would cast a vote for
                            // "unclassified" and, at this path's density,
                            // bury every real classification the mesh path
                            // contributed.
                            classificationRawValue: VoxelAccumulator.unclassifiedRawValue,
                            isConfidenceObserved: true
                        )
                    )
                }

                x += stride
            }
            y += stride
        }

        ingestDepthSamples(depthSamples)

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

    /// Surface normal at a depth pixel, from the depth map itself.
    ///
    /// Estimated the standard way: unproject this pixel and its right and
    /// down neighbours, and take the cross product of the two edge vectors
    /// between them. That is a real measurement of the local surface, not a
    /// placeholder — which matters because these normals are written into
    /// the PLY/LAS export, where downstream meshing and rendering depend on
    /// them. Returns `nil` rather than a made-up direction when either
    /// neighbour is missing or invalid (depth discontinuity, edge of the
    /// map), so a point is only given a normal that was actually derived.
    ///
    /// Neighbours are taken `stride` pixels away, matching the sampling
    /// grid: adjacent raw pixels are noisier relative to their tiny
    /// baseline, which makes the cross product jitter.
    private static func surfaceNormal(
        atX x: Int,
        y: Int,
        cameraPoint: SIMD3<Float>,
        stride: Int,
        width: Int,
        height: Int,
        depthBuffer: UnsafeMutablePointer<Float32>,
        depthBytesPerRow: Int,
        intrinsics: CameraUnprojection.Intrinsics
    ) -> SIMD3<Float>? {
        let rightX = x + stride
        let downY = y + stride
        guard rightX < width, downY < height else { return nil }

        let rightDepth = depthBuffer.advanced(by: (y * depthBytesPerRow) / MemoryLayout<Float32>.size)[rightX]
        let downDepth = depthBuffer.advanced(by: (downY * depthBytesPerRow) / MemoryLayout<Float32>.size)[x]
        guard ProScanConfig.isDepthValid(rightDepth), ProScanConfig.isDepthValid(downDepth) else { return nil }

        // A large depth jump between neighbours means they sit on different
        // surfaces (an object's edge against the wall behind it), and the
        // "surface" through all three is fictional. Scaled with distance
        // because depth noise grows with range.
        let discontinuityLimit = max(0.05, -cameraPoint.z * 0.1)
        guard abs(rightDepth + cameraPoint.z) < discontinuityLimit,
              abs(downDepth + cameraPoint.z) < discontinuityLimit else { return nil }

        let right = CameraUnprojection.unproject(pixel: SIMD2<Float>(Float(rightX), Float(y)), depth: rightDepth, intrinsics: intrinsics)
        let down = CameraUnprojection.unproject(pixel: SIMD2<Float>(Float(x), Float(downY)), depth: downDepth, intrinsics: intrinsics)

        let normal = simd_cross(right - cameraPoint, down - cameraPoint)
        let length = simd_length(normal)
        guard length > 0, length.isFinite else { return nil }
        let unit = normal / length

        // Orient toward the camera (which sits at the origin in camera
        // space, so the direction to it is just `-cameraPoint`). Without
        // this, whether a normal points into or out of the surface depends
        // on the handedness of the pixel grid — half the cloud would face
        // inward.
        return simd_dot(unit, -simd_normalize(cameraPoint)) < 0 ? -unit : unit
    }

    /// Folds a frame's depth samples into the dense accumulator.
    ///
    /// Hops onto `meshProcessingQueue` rather than doing this inline: the
    /// caller runs on `delegateQueue`, and taking `meshLock` there for a
    /// couple of thousand samples would put the accumulator's work directly
    /// in the path of ARKit's frame delivery — exactly the delegate-queue
    /// backlog the architecture audit traced the freezing/islanding mesh to
    /// (finding C4). Reusing the mesh queue rather than adding a third one
    /// also keeps every mutation of accumulator state serialized against the
    /// mesh pipeline's, in the order it was produced.
    private func ingestDepthSamples(_ samples: [VoxelAccumulator.Sample]) {
        guard !samples.isEmpty else { return }
        meshProcessingQueue.async { [weak self] in
            guard let self else { return }
            self.meshLock.lock()
            defer { self.meshLock.unlock() }

            // Bounded by occupied voxels, not observations — see
            // `ProScanConfig.maximumDepthVoxelCount`. Like every other budget
            // in this pipeline, hitting it stops further ingestion and keeps
            // everything already captured.
            guard self.fusedAccumulator.observedVoxelCount < ProScanConfig.maximumDepthVoxelCount else { return }

            self.fusedAccumulator.record(contentsOf: samples)
            self.depthSampleCountTotal += samples.count
        }
    }

    /// BT.601 full-range YCbCr → RGB, sampled at a single luma pixel (and
    /// its corresponding half-resolution chroma pixel).
    ///
    /// Read-only pointers: `processFrame` passes pointers sourced from a
    /// locked `CVPixelBuffer` (an `UnsafeMutableRawPointer` implicitly
    /// converts at the call site), and `processMeshAnchor` passes pointers
    /// into a `MeshFrameSnapshot`'s plain `[UInt8]` arrays — neither caller
    /// needs to mutate through these, so read-only is the honest type.
    private static func sampleColor(
        lumaBase: UnsafeRawPointer?,
        lumaBytesPerRow: Int,
        chromaBase: UnsafeRawPointer?,
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
        recordDelegateFrameMetrics(for: frame)
        // Fase 3, finding E4 — unconditional, same reasoning as
        // `angularVelocityGate`'s update just below: both need every
        // frame's transform, not just the ones the throttled pipelines
        // below choose to process.
        driftBudget.record(transform: frame.camera.transform)
        if !hasNotifiedDriftBudgetExceeded, driftBudget.isExhausted {
            hasNotifiedDriftBudgetExceeded = true
            onDriftBudgetExceeded?()
        }
        // Evaluated once per delivered frame, unconditionally — both
        // `processFrame` below and `updateMeshAnchors` (reacting to
        // `didAdd`/`didUpdate` anchors for this same frame) read the result
        // via `isCurrentFrameMotionAcceptable` rather than each maintaining
        // their own `AngularVelocityGate` state, which would let the two
        // pipelines disagree about the same frame.
        isCurrentFrameMotionAcceptable = angularVelocityGate.isMotionAcceptable(
            transform: frame.camera.transform, timestamp: frame.timestamp
        )
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

    /// Folds this callback's arrival into `delegateFrameMetrics` and
    /// publishes a snapshot at most once a second — Fase 0 of the
    /// architecture audit. Runs on every single `didUpdate frame:` call,
    /// unconditionally, unlike `processFrame` (throttled to
    /// `ProScanConfig.depthSampleHz`): the delegate-queue backlog this
    /// measures is a property of every frame ARKit delivers, not just the
    /// ones the depth pipeline happens to process.
    ///
    /// The recording itself is two `Int`/`Double` accumulations — the same
    /// negligible cost class as the throttle check `PointCloudStore.ingest`
    /// already does on this queue (Fase 1, finding C5) — so doing it
    /// unconditionally does not reintroduce the kind of per-frame cost that
    /// phase worked to remove. The publish this throttles, not the
    /// recording, is what would be expensive to do 60 times a second: it
    /// hops onto the main actor for `PerformanceMonitor`'s `@Published`
    /// properties, by the same reasoning as that same fix.
    private func recordDelegateFrameMetrics(for frame: ARFrame) {
        let now = CACurrentMediaTime()
        delegateFrameMetrics.record(frameTimestamp: frame.timestamp, now: now)

        guard now - lastMetricsPublishAt >= Self.metricsPublishIntervalSeconds,
              let snapshot = delegateFrameMetrics.snapshot(now: now) else { return }
        lastMetricsPublishAt = now
        delegateFrameMetrics.reset()
        onPerformanceSample?(snapshot)
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

    /// Deliberately keeps everything the removed anchor contributed.
    ///
    /// This used to delete those points, which quietly made Pro Scan a
    /// *sliding window* instead of a scan: ARKit's scene reconstruction only
    /// maintains mesh anchors for the region around the device, and removes
    /// them as you walk away from what they cover. Deleting on removal
    /// therefore threw away the earlier half of every walked scan — a 61 s
    /// pass exported ~10 k points where a 13 s pass from one spot exported
    /// ~17 k, and what survived was only whatever had been scanned last.
    ///
    /// A removal means ARKit stopped tracking that chunk, not that the
    /// surface was never observed: the samples were measured, reprojected
    /// under reliable tracking, and are as real as any other. Re-walking an
    /// area is safe too — the returning anchors are new identifiers, and
    /// `VoxelAccumulator` fuses their samples into the same voxels rather
    /// than stacking duplicates.
    ///
    /// Unbounded growth is already handled where it belongs, by
    /// `ProScanConfig.maximumMeshPointBudget` in `updateMeshAnchors`, which
    /// stops *further* ingestion instead of discarding what's captured.
    ///
    /// Retriangulation of a still-live anchor is a different case and still
    /// replaces that anchor's own contribution — see `processMeshAnchor`.
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {}

    /// Runs on `delegateQueue`. Evaluates every guard synchronously — same
    /// as before this phase — so a scan that's budget-exceeded, tracking
    /// unreliably, or mid-relocalization never even pays for a frame
    /// snapshot, let alone a queue hop. Only once every guard passes does
    /// this copy the frame's color image (`makeMeshFrameSnapshot`, the one
    /// piece of frame-scoped data mesh processing cannot safely read
    /// later) and dispatch the actual per-vertex work onto
    /// `meshProcessingQueue` — see that property's doc comment for why
    /// this split exists at all (audit finding C4).
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
        // Fase 2, finding E1 — see `processFrame`'s identical guard and
        // `AngularVelocityGate`'s doc comment. A mesh chunk reprojected
        // using a motion-blurred frame's color/depth is exactly as
        // unreliable here as a raw depth sample would be.
        guard isCurrentFrameMotionAcceptable else { return }
        // A fixed, conservative ceiling on total accumulated points — see
        // `ProScanConfig.maximumMeshPointBudget`. Existing data is kept
        // as-is (never discarded); only *further* ingestion stops, so a
        // very large or very long scan degrades gracefully instead of
        // growing memory use without bound.
        guard !ProScanConfig.isMeshPointBudgetExceeded(currentCount: currentMeshPointCount()) else { return }

        let meshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { return }
        guard let snapshot = Self.makeMeshFrameSnapshot(from: frame) else { return }

        // Fase 2, finding C8: read once for this whole batch, not once per
        // anchor inside the loop below — see `processMeshAnchor`'s doc
        // comment on why that's correct, not just cheaper.
        let thermalState = ProcessInfo.processInfo.thermalState
        meshProcessingQueue.async { [weak self] in
            guard let self else { return }
            for anchor in meshAnchors {
                self.processMeshAnchor(anchor, frame: snapshot, thermalState: thermalState)
            }
        }
    }

    /// Fase 3, finding E6: before surfacing this to the user, check whether
    /// it's the transient single-active-session conflict
    /// `ARSessionStartupPolicy` exists to retry — see that type's doc
    /// comment. A failure long after a successful `run()` (the ordinary
    /// "real" failure this delegate method existed to report before this
    /// phase) falls outside the policy's early-failure window and is
    /// surfaced exactly as before.
    func session(_ session: ARSession, didFailWithError error: Error) {
        let secondsSinceRun = CACurrentMediaTime() - lastRunAttemptTimestamp
        let decision = ARSessionStartupPolicy.decision(afterFailureAt: secondsSinceRun, attempt: startupAttemptCount)
        switch decision {
        case .retry(let afterSeconds):
            guard isActive else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + afterSeconds) { [weak self] in
                guard let self, self.isActive else { return }
                self.attemptStart()
            }
        case .giveUp:
            onFailure?(error.localizedDescription)
        }
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
        // Fase 3, finding E4 — see `ScanDriftBudget.discardPreviousTransform`'s
        // doc comment for why the *comparison baseline* (not the
        // accumulated counters) must be dropped across an interruption.
        driftBudget.discardPreviousTransform()
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
