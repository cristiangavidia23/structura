import simd

/// Anchors Pro Scan's local frame to a real-world site coordinate via a
/// single control point: one correspondence between a position already
/// measured in the scan (in the same +Z-up frame `LASExporter` writes,
/// i.e. *after* `TopographicAxisConvention`) and its known coordinate in
/// the project's own local/site coordinate system — meters, e.g. an
/// established site benchmark or control point, not a geodetic lat/lon or
/// UTM projection.
///
/// **Translation only, by design.** A single point supplies exactly the
/// three constraints (X, Y, Z) needed to fix an origin shift, and nothing
/// more — it cannot determine rotation; that would need a second point or
/// an independent bearing reference, neither of which this type accepts.
/// Pro Scan also captures with `worldAlignment = .gravity` (see
/// `ARPointCloudSession`), not `.gravityAndHeading`, so there is no
/// compass/heading reference at capture time either. Applying this
/// transform anchors the scan's *position* to a real coordinate; it does
/// **not** verify or correct horizontal orientation against true or grid
/// north. `ScanMetadataReport` and the WKT `LASExporter` writes both state
/// that caveat explicitly rather than imply a fully-georeferenced result.
struct ControlPointTransform {
    /// The control point's position as measured in the scan, in the same
    /// +Z-up frame `LASExporter` writes (already passed through
    /// `TopographicAxisConvention.convert`).
    var measuredLocalPosition: SIMD3<Float>
    /// The same physical point's known coordinate in the project's local
    /// site coordinate system, in meters.
    var knownRealCoordinate: SIMD3<Float>
    /// Declared accuracy of `knownRealCoordinate`, in meters (e.g. how the
    /// control point itself was established) — carried through to
    /// `ScanMetadataReport`. `nil` if not supplied; never fabricated.
    var declaredAccuracyMeters: Double?

    private var offset: SIMD3<Float> {
        knownRealCoordinate - measuredLocalPosition
    }

    /// Applies the translation to a position already in the +Z-up frame.
    func apply(_ zUpPosition: SIMD3<Float>) -> SIMD3<Float> {
        zUpPosition + offset
    }
}
