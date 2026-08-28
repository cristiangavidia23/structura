import ARKit

/// Frame-level accumulation gate for Pro Scan's two capture pipelines (raw
/// per-frame depth and fused-mesh export). Fase 1 wires only the
/// tracking-state check below — per-frame motion (angular velocity) and
/// `worldMappingStatus` gating are architected for here (see the Pro Scan
/// audit's target pipeline diagram) but land in a later phase, once there
/// is a previous-frame reference to compare against and a defined recovery
/// path for a broken coordinate frame after an interruption.
///
/// Depends on ARKit (for `ARCamera.TrackingState`), unlike `ProScanConfig`
/// and `CameraUnprojection` — so this file is compiled only into the
/// `Structura` app target, not into the host-less `StructuraTests` bundle.
enum FrameGate {
    /// Requiring strict `.normal` tracking dropped *every* mesh-anchor
    /// update that happened to land during a `.limited` moment — and on a
    /// handheld scan, tracking flickers into `.limited` constantly (fast
    /// pans, low light, a blank wall with no texture to lock onto). Since
    /// each drop discards that whole chunk's update rather than just
    /// flagging it, the practical effect was large disconnected gaps in the
    /// captured mesh (confirmed on a real 55 s scan: 2% bounding-box
    /// coverage, isolated islands) — correctness-over-coverage taken far
    /// enough to make coverage the actual failure mode.
    ///
    /// `.limited(.insufficientFeatures)` and `.limited(.excessiveMotion)`
    /// still carry a real, usable pose estimate from ARKit (just a lower
    /// confidence one) — they're the common case during ordinary handheld
    /// motion, not a broken coordinate frame. `.limited(.initializing)`,
    /// `.limited(.relocalizing)`, and `.notAvailable` are excluded: those
    /// mean ARKit doesn't have a trustworthy pose *at all* yet (session
    /// startup, or actively recovering from a lost coordinate frame), where
    /// unprojecting against "whatever transform it has right now" really
    /// would be indistinguishable from noise.
    static func isTrackingReliable(_ state: ARCamera.TrackingState) -> Bool {
        switch state {
        case .normal:
            return true
        case .limited(.insufficientFeatures), .limited(.excessiveMotion):
            return true
        case .limited(.initializing), .limited(.relocalizing), .notAvailable:
            return false
        @unknown default:
            return false
        }
    }
}
