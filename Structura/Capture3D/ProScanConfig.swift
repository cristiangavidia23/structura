import Foundation
import simd

/// Single source of truth for every physical/numeric constant the Pro Scan
/// pipeline depends on. Each value below documents where it comes from — a
/// hardware/ARKit-documented behavior, a value already shipping elsewhere in
/// the app (kept here to avoid a second hardcoded copy), or an engineering
/// placeholder that still needs field calibration. Nothing here should be
/// re-declared inline anywhere else in `Capture3D` or `Export/PointCloud`.
///
/// Coordinate-system assumption used throughout this file and everywhere it
/// is consumed: ARKit's world and camera spaces are **right-handed, +Y up**
/// (`ARFrame`/`ARCamera`, Apple's documented convention). Export targets
/// such as some CAD/GIS pipelines assume **+Z up** instead — any conversion
/// between the two happens at the export boundary (`Export/PointCloud`),
/// never here; this file only describes ARKit-space quantities.
enum ProScanConfig {

    // MARK: - Depth validity

    /// Depth samples outside this range are discarded before they ever reach
    /// the accumulator. Apple documents the LiDAR scanner's practical range
    /// as up to roughly 5 m; readings much closer than ~0.25 m are dominated
    /// by the sensor's minimum focus distance rather than real geometry.
    /// These bounds are a conservative starting point, not a number lifted
    /// from a specific published spec sheet — Fase 1's synthetic-plane tests
    /// and on-device field testing should confirm (or tighten) them before
    /// they are treated as final.
    static let validDepthRangeMeters: ClosedRange<Float> = 0.25...5.0

    // MARK: - Confidence gating

    /// `ARConfidenceLevel` (ARKit, `ARDepthData.h`, verified against the
    /// installed iOS 26.5 SDK) is `Low = 0`, `Medium = 1`, `High = 2`.
    /// `ARPointCloudSession` normalizes a raw confidence sample as
    /// `confidenceRaw / Float(ARConfidenceLevel.high.rawValue)` — i.e.
    /// divides by 2 — so `.medium` corresponds to a normalized value of 0.5.
    /// Kept as plain numbers here rather than typed as `ARConfidenceLevel`
    /// directly, so this file has no ARKit dependency and can be compiled
    /// into the host-less `StructuraTests` logic-test target without
    /// linking the framework.
    static let minimumConfidenceRawLevel: Int = 1 // ARConfidenceLevel.medium
    static let minimumNormalizedConfidence: Float = 0.5

    /// `ARConfidenceLevel.high.rawValue` — used as the assumed confidence
    /// when a frame's `confidenceMap` is missing entirely (rather than
    /// merely low-confidence at a given pixel), matching the choice already
    /// shipping in `ARPointCloudSession.swift`, and as the divisor that
    /// normalizes a raw confidence sample to the 0...1 range used
    /// everywhere else in this file.
    static let maximumConfidenceRawLevel: Int = 2 // ARConfidenceLevel.high

    /// Normalizes a raw `ARConfidenceLevel`-scale sample (0...2) to the
    /// 0...1 range `minimumNormalizedConfidence` and the rest of the
    /// pipeline compare against.
    static func normalizedConfidence(fromRaw raw: Float) -> Float {
        raw / Float(maximumConfidenceRawLevel)
    }

    /// Depth-validity predicate built from `validDepthRangeMeters` above —
    /// centralized here so every call site checks the same range the same
    /// way, rather than re-deriving `isFinite && range.contains(...)`
    /// independently at each of Pro Scan's two capture pipelines.
    static func isDepthValid(_ depth: Float) -> Bool {
        depth.isFinite && validDepthRangeMeters.contains(depth)
    }

    /// Confidence-acceptance predicate built from `minimumNormalizedConfidence`.
    static func isConfidenceAcceptable(_ normalizedConfidence: Float) -> Bool {
        normalizedConfidence.isFinite && normalizedConfidence >= minimumNormalizedConfidence
    }

    // MARK: - Spatial deduplication

    /// Voxel edge length used to snap nearby samples together before
    /// they're treated as the same physical point. Matches the value
    /// already shipping in `PointCloudStore.swift` — centralized here so
    /// the voxel accumulator introduced in a later phase uses the same
    /// constant instead of a second hardcoded copy that could silently
    /// drift from this one.
    static let voxelSizeMeters: Float = 0.02

    /// The single source of truth for turning a world-space position into a
    /// voxel-grid cell key, at `voxelSizeMeters` resolution — three 21-bit
    /// signed cell coordinates packed into one `Int64` (comfortably covers
    /// any room-scale scan: ±5,000 cells ≈ ±100 m at this voxel size,
    /// without allocating a struct key per point).
    ///
    /// Fase 2 of the architecture audit (finding E3): the exact same
    /// packing scheme used to be hand-copied in three places
    /// (`VoxelAccumulator.voxelKey(for:)`, `ConfidenceGrid.voxelKey(for:)`,
    /// `PointCloudStore.voxelKey(for:)`) — correct today, but a change to
    /// the scheme in only one of them would silently desynchronize how the
    /// mesh accumulator, the confidence grid, and the raw-depth accumulator
    /// bucket the same physical space. All three now forward to this
    /// function instead of keeping their own copy.
    static func voxelKey(for position: SIMD3<Float>) -> Int64 {
        let x = Int64((position.x / voxelSizeMeters).rounded()) & 0x1FFFFF
        let y = Int64((position.y / voxelSizeMeters).rounded()) & 0x1FFFFF
        let z = Int64((position.z / voxelSizeMeters).rounded()) & 0x1FFFFF
        return (x << 42) | (y << 21) | z
    }

    // MARK: - Motion gating

    /// Frames where the camera's angular velocity exceeds this threshold
    /// should be dropped rather than accumulated: fast rotation between two
    /// frames means the depth/mesh sample is more likely to reflect motion
    /// blur than real geometry. This number is an engineering placeholder —
    /// ARKit does not publish a validated threshold for this — and must be
    /// tuned against real device recordings once the gating that consumes
    /// it lands; treat it as a starting point, not a calibrated physical
    /// limit.
    static let maximumAngularVelocityRadiansPerSecond: Float = 1.0

    // MARK: - Sampling cadence

    /// Target rate for the per-frame depth pipeline.
    ///
    /// This rate used to be justified as "a confidence/coverage signal
    /// only, never the export path" — 6 Hz was plenty for a coverage HUD.
    /// That reasoning no longer holds: the depth stream is now folded into
    /// the accumulated cloud itself (see `ARPointCloudSession.processFrame`),
    /// which makes it the *dense* source of the export, not a side signal.
    /// Every frame skipped here is geometry never captured.
    ///
    /// 12 Hz is the compromise: at a normal hand-sweep pace (~0.3 m/s) that
    /// puts successive frames roughly one voxel apart, so a sweep leaves no
    /// gap, while still being a fraction of ARKit's 60 Hz — the delegate-
    /// queue backlog the audit flagged is real, and the unprojection loop is
    /// the expensive part of it. An engineering placeholder: the
    /// coverage-versus-thermals curve this should be read off has not been
    /// measured on real hardware yet.
    static let depthSampleHz: Double = 12.0

    /// Every Nth mesh vertex is kept when extracting an `ARMeshAnchor`'s
    /// geometry. Matches the value already shipping in
    /// `ARPointCloudSession.swift`.
    static let meshVertexStride: Int = 3

    /// Every Nth depth-map pixel is sampled per row/column in the raw
    /// per-frame pipeline. Matches the value already shipping in
    /// `ARPointCloudSession.swift`.
    static let depthPixelStride: Int = 5

    // MARK: - Ingesta de profundidad (nube densa)

    /// Ceiling on distinct occupied voxels retained from depth ingestion,
    /// above which further depth frames are dropped.
    ///
    /// This is the bound that actually matters for depth: individual depth
    /// samples are folded into their voxel and never retained separately,
    /// so memory tracks *occupied voxels*, not observations. A 2 cm voxel
    /// only ever holds surfaces, so a room lands in the low hundreds of
    /// thousands; this leaves room for a whole floor before it engages.
    ///
    /// Like `maximumMeshPointBudget`, a deliberately conservative fixed
    /// number rather than a live `os_proc_available_memory()` reading —
    /// and, like it, it stops *further ingestion* instead of discarding
    /// what has already been captured. Provisional until profiled on a
    /// real long scan.
    static let maximumDepthVoxelCount: Int = 1_200_000

    /// Under thermal pressure, widen the depth-map stride for the same
    /// reason `meshVertexStride(forThermalState:)` does — fewer samples per
    /// frame instead of an ever-climbing load that would push ARKit's own
    /// tracking quality down with it.
    static func depthPixelStride(forThermalState state: ProcessInfo.ThermalState) -> Int {
        switch state {
        case .nominal, .fair:
            return depthPixelStride
        case .serious:
            return depthPixelStride * 2
        case .critical:
            return depthPixelStride * 3
        @unknown default:
            return depthPixelStride
        }
    }

    // MARK: - Session duration

    /// Pro Scan has no loop closure or relocalization, so drift grows with
    /// session length. Matches the value already shipping in
    /// `ProScanCoordinator.swift` — centralized here rather than duplicated.
    static let recommendedMaxDurationSeconds: Int = 40

    // MARK: - Adaptive resource budget

    /// Under thermal pressure, widen the mesh-vertex stride (sample fewer
    /// vertices per chunk) rather than let CPU/GPU load keep climbing and
    /// risk ARKit itself degrading tracking quality further.
    /// `ProcessInfo.ThermalState` is the standard, Apple-documented signal
    /// for this — checked once per mesh-anchor update in
    /// `ARPointCloudSession` (a per-event cost, not a per-vertex one).
    static func meshVertexStride(forThermalState state: ProcessInfo.ThermalState) -> Int {
        switch state {
        case .nominal, .fair:
            return meshVertexStride
        case .serious:
            return meshVertexStride * 2
        case .critical:
            return meshVertexStride * 4
        @unknown default:
            return meshVertexStride
        }
    }

    /// A conservative fixed ceiling on total accumulated (pre-dedup) mesh
    /// points, above which `ARPointCloudSession` stops ingesting further
    /// mesh updates rather than growing without bound. This is a simple
    /// fixed budget, not a real-time memory-pressure calculation against
    /// `os_proc_available_memory()` — an honest placeholder pending real
    /// on-device profiling of how many points a scan can hold before memory
    /// becomes a problem. The export pipeline is no longer that limit:
    /// `PLYExporter` and `LASExporter` both stream to disk in batches now
    /// (the audit's finding that they assembled whole files in memory has
    /// been resolved), so what this budget bounds is the accumulated cloud
    /// itself. Treat this number as provisional.
    static let maximumMeshPointBudget: Int = 4_000_000

    static func isMeshPointBudgetExceeded(currentCount: Int) -> Bool {
        currentCount >= maximumMeshPointBudget
    }

    // MARK: - Export precision

    /// LAS X/Y/Z scale factor (ASPRS LAS 1.4 §2.4: "the corresponding X, Y,
    /// or Z scale factor must be multiplied by the X, Y, or Z point record
    /// value to get the actual coordinate"). 1 mm keeps the `Int32` record
    /// value comfortably inside range for any room/building-scale scan
    /// while representing sub-millimeter precision loss only from rounding
    /// — LiDAR mesh vertices don't carry real sub-mm accuracy in the first
    /// place, so this is not the limiting factor on file precision.
    static let lasScaleFactorMeters: Double = 0.001

    // MARK: - Session interruption recovery

    /// After `sessionInterruptionEnded`, ARKit typically resumes tracking
    /// in the same coordinate frame on its own, but a vanilla `ARSession`
    /// (without an explicit `ARWorldMap` to relocalize against) gives no
    /// hard guarantee the origin didn't shift — silently trusting the very
    /// next frame would repeat the bug this phase fixes. Instead, once
    /// tracking is back, require this many *consecutive* `.normal`-state
    /// frames before treating the frame as trustworthy again. At up to 60
    /// fps this is roughly one second — a placeholder, not a value derived
    /// from a measured relocalization-confidence curve, since ARKit doesn't
    /// publish one; tune against real interruption recordings before
    /// treating it as final.
    static let relocalizationConfirmationFrameCount: Int = 60

    // MARK: - Resource guards

    /// Below this much free disk space, `ProScanCoordinator` stops the
    /// capture rather than risk a failed autosave or final export losing
    /// the scan outright. 200 MB is a conservative placeholder sized for a
    /// worst-case in-memory PLY+LAS pair of a large scan (see
    /// `ProScanConfig.maximumMeshPointBudget`), not a measured minimum.
    static let minimumFreeDiskSpaceBytes: Int64 = 200 * 1024 * 1024

    /// Below this battery fraction (0...1), *while unplugged*, the capture
    /// stops rather than risk the device dying mid-scan with unsaved work.
    /// Ignored while charging/full, since battery drain isn't a
    /// scan-continuity risk in that case. A conservative placeholder, not
    /// a measured "how much battery does one more minute of Pro Scan cost"
    /// figure.
    static let minimumBatteryLevelWhileUnplugged: Float = 0.10

    /// `.critical` thermal state is ARKit/iOS's own strongest signal that
    /// continuing to run the camera + neural engine + GPU is actively
    /// harming device performance (and, per Apple's guidance, tracking
    /// quality degrades further under sustained thermal pressure) — stop
    /// rather than let the OS itself start throttling capture out from
    /// under the user without warning.
    static func shouldAbortCapture(forThermalState state: ProcessInfo.ThermalState) -> Bool {
        state == .critical
    }

    // MARK: - Autosave

    /// How often the in-progress mesh is snapshotted to disk (as PLY,
    /// attached to the scan's existing `ScanRecord`) during a live Pro Scan
    /// pass — the mechanism that lets a scan survive the app being killed
    /// outright, not just backgrounded. 10 s balances "don't lose much
    /// work" against constant background PLY-encoding/disk-write cost; a
    /// starting point, not a value tuned against real device I/O cost.
    static let autosaveIntervalSeconds: Double = 10.0

    // MARK: - Measurement (post-capture, `Result/`)

    /// Radius searched around a tapped point to fit a local plane for
    /// "snap to plane" — wide enough to average out per-point noise, narrow
    /// enough to stay local to one real surface rather than blending two
    /// adjacent ones. Deliberately coarser than `voxelSizeMeters` (that one
    /// dedupes near-duplicate samples of the *same* point; this one
    /// characterizes the *local surface* around a point). A starting point
    /// pending real-scan tuning, not a calibrated figure.
    static let planeFitNeighborhoodRadiusMeters: Float = 0.05

    /// Above this angular spread (the largest angle between any two normals
    /// in the fit neighborhood, in radians — see `PlaneSnapping
    /// .maxAngularSpread`), the neighborhood is judged "not flat enough" to
    /// trust a single plane, and the raw tapped point is used instead of a
    /// plane-projected one. ~15°, converted to radians — a conservative
    /// placeholder; the honest failure mode here is falling back to the
    /// (already-correct-by-construction) raw point, not fabricating a plane
    /// that isn't really there.
    static let maximumPlanarAngularSpreadRadians: Float = 15 * .pi / 180

    /// Minimum neighbor count for a plane fit to be trusted at all — a
    /// "plane" fit from only 1-2 points is really just noise wearing a
    /// normal vector; below this, fall back to the raw point.
    static let minimumPlaneFitNeighborCount: Int = 6

    /// Maximum perpendicular distance, in meters, from a tap's projected
    /// 3D ray to the nearest point cloud sample for a raycast hit to count
    /// at all — beyond this, the tap is treated as having missed the scan
    /// entirely. Scaled to typical LiDAR sample spacing at a few meters'
    /// range, not a measured "how precise is a fingertip tap" figure.
    static let raycastMaxPerpendicularDistanceMeters: Float = 0.05

    /// Voxel size used only by the post-capture coverage/"holes" estimate
    /// in the QA panel — deliberately coarser than `voxelSizeMeters` (that
    /// one dedupes near-duplicate point observations; this one asks "is
    /// there roughly *any* data in this neighborhood at all", a much
    /// looser question). A starting point for what "coverage" means
    /// visually, not a calibrated resolution.
    static let coverageVoxelSizeMeters: Float = 0.10

    /// A scan running longer than this, `ResultView`'s QA panel flags an
    /// elevated drift-risk warning — matches `recommendedMaxDurationSeconds`
    /// (the same threshold already shown live during capture), surfaced
    /// again after the fact since a scan can be reviewed long after it was
    /// captured, when the in-capture banner is long gone.
    static func isDriftRiskElevated(durationSeconds: Int) -> Bool {
        durationSeconds > recommendedMaxDurationSeconds
    }
}
