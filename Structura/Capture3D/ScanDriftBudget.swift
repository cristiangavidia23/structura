import Foundation
import simd

/// A proxy for how much ARKit position drift a Pro Scan pass has likely
/// accumulated, replacing a flat elapsed-time cutoff — Fase 3 of the
/// architecture audit, finding E4.
///
/// Pro Scan has no loop closure, so real drift (the gap between ARKit's
/// estimated position and the physical world) can't be measured directly.
/// But it correlates far more with how much the camera has actually moved
/// and turned than with wall-clock time: a pass that lingers in one small
/// area for 60 s accumulates much less real drift than one that sweeps
/// quickly through a large space in 20 s. The previous mitigation
/// (`ProScanCoordinator.recommendedMaxDuration`, a flat 40 s) penalized the
/// former and under-warned the latter.
///
/// Pure `simd`/`Foundation` — no ARKit dependency — so, like
/// `AngularVelocityGate` (whose rotation-angle math this reuses rather than
/// duplicating), this compiles into the host-less `StructuraTests` target
/// and is exercised with synthetic transforms, not a real device.
struct ScanDriftBudget {
    private(set) var traveledDistanceMeters: Float = 0
    private(set) var accumulatedRotationRadians: Float = 0
    private var previousTransform: simd_float4x4?

    /// Engineering placeholders, not calibrated against a real drift
    /// measurement — there is no ground truth available without loop
    /// closure to compare against. Chosen so a typical careful room-scale
    /// pass (a few meters of walking, a few full turns while covering the
    /// space) lands comfortably under the budget, while a pass that has
    /// clearly covered a lot of ground or spun around many times exhausts
    /// it. These need real-device tuning once there's a way to measure
    /// actual drift to compare against.
    static let maximumTraveledDistanceMeters: Float = 15
    /// About 4 full turns — generous for the normal back-and-forth
    /// reorientation of scanning a room, while still catching a pass that
    /// has spun in place many times.
    static let maximumAccumulatedRotationRadians: Float = 4 * 2 * .pi

    /// Feed one frame's camera transform. The first call after `reset()`/
    /// `discardPreviousTransform()` only establishes the comparison
    /// baseline — nothing is accumulated until the *next* call, since a
    /// single transform alone has no distance/rotation to measure against.
    mutating func record(transform: simd_float4x4) {
        defer { previousTransform = transform }
        guard let previous = previousTransform else { return }

        let previousTranslation = SIMD3<Float>(previous.columns.3.x, previous.columns.3.y, previous.columns.3.z)
        let translation = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        traveledDistanceMeters += simd_distance(previousTranslation, translation)
        accumulatedRotationRadians += AngularVelocityGate.rotationAngleRadians(from: previous, to: transform)
    }

    /// Fraction of the budget consumed so far, across both dimensions —
    /// whichever is further along. `>= 1.0` means the budget is exhausted.
    /// Deliberately not clamped to `1.0`: a caller that wants a progress
    /// value rather than just a boolean can use the raw, unbounded
    /// fraction.
    var consumedFraction: Float {
        max(
            traveledDistanceMeters / Self.maximumTraveledDistanceMeters,
            accumulatedRotationRadians / Self.maximumAccumulatedRotationRadians
        )
    }

    var isExhausted: Bool { consumedFraction >= 1.0 }

    /// Full reset — both cumulative counters and the comparison baseline.
    /// Called when a fresh Pro Scan pass starts.
    mutating func reset() {
        traveledDistanceMeters = 0
        accumulatedRotationRadians = 0
        previousTransform = nil
    }

    /// Discards only the comparison baseline, keeping the cumulative
    /// counters as they are — called when a session interruption ends, so
    /// the next frame's transform (which can differ arbitrarily from the
    /// last pre-interruption one, since a vanilla `ARSession` has no hard
    /// guarantee the coordinate origin survived intact) isn't compared
    /// against it as if it were ordinary continuous motion. That
    /// comparison would otherwise attribute a coordinate-frame
    /// discontinuity to the budget, as if the user had physically covered
    /// that distance in an instant — a different failure mode than the one
    /// this budget is meant to catch, and one `isCoordinateFrameBroken`'s
    /// own gating already refuses to accumulate scan data across anyway.
    mutating func discardPreviousTransform() {
        previousTransform = nil
    }
}
