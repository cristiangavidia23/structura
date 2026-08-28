/// A minimal, honest WKT1 `LOCAL_CS` declaration for Pro Scan's default
/// (no control point) export path: an arbitrary local Cartesian frame, in
/// meters, with **no** claim about true/grid north alignment.
///
/// LAS 1.4 requires a CRS declaration for every file using Point Data
/// Record Formats 6-10 (ASPRS LAS Specification 1.4 - R15, §3: "The
/// Coordinate Reference System (CRS) information for the point data is
/// required for all data... Point Data Record Formats 6-10 must use WKT").
/// Omitting it isn't an option once `LASExporter` writes PDRF 7 — and
/// silently leaving Civil3D/ArcGIS to report "unknown coordinate system"
/// (the audit's original finding) is worse than declaring an honest local
/// frame with its real, limited meaning stated plainly.
///
/// Pro Scan captures with `worldAlignment = .gravity` (see
/// `ARPointCloudSession`, `TopographicAxisConvention`), not
/// `.gravityAndHeading` — there is no compass/heading reference at capture
/// time. This WKT deliberately omits `AXIS` direction labels (e.g.
/// `NORTH`/`EAST`) rather than assert a horizontal alignment that was never
/// established.
enum LocalEngineeringCRS {
    static let wktDescription = "LOCAL_CS[\"Structura Pro Scan local frame (arbitrary horizontal orientation, vertical aligned to gravity)\",LOCAL_DATUM[\"Unknown\",0],UNIT[\"metre\",1.0]]"

    /// Same local/arbitrary-horizontal-orientation caveat as
    /// `wktDescription`, worded for the `ControlPointTransform` case: the
    /// *origin* (not the orientation) has been anchored to a real project
    /// control point. Still a `LOCAL_CS`, not a real geodetic/projected
    /// CRS — `ControlPointTransform` is translation-only (see its doc
    /// comment for why), so asserting a true/grid-north-aligned CRS here
    /// would claim a verification that never happened.
    static func wktDescriptionAnchoredToControlPoint(declaredAccuracyMeters: Double?) -> String {
        let accuracyClause = declaredAccuracyMeters.map { String(format: ", control point accuracy ±%.3f m", $0) } ?? ""
        return "LOCAL_CS[\"Structura Pro Scan local frame, origin anchored to a project control point (position only — horizontal orientation not verified against true/grid north\(accuracyClause))\",LOCAL_DATUM[\"Unknown\",0],UNIT[\"metre\",1.0]]"
    }
}
