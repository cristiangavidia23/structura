import simd

/// Converts a position from ARKit's world-space convention (right-handed,
/// +Y up, camera looking down -Z at session start) to the right-handed,
/// +Z-up convention civil/CAD tooling — Civil3D, and topographic surveying
/// generally — expects: elevation on Z, horizontal plane on X/Y.
///
/// This is a 90° rotation about the X axis, `(x, y, z) → (x, -z, y)`,
/// chosen because it preserves handedness (determinant +1 — a rotation,
/// not a mirror/reflection): ARKit's +Y (up) becomes the new +Z (up), and
/// ARKit's -Z (the direction the camera faced when the session started)
/// becomes the new +Y.
///
/// **Important caveat**: this fixes *vertical* orientation only. Pro Scan
/// captures with `worldAlignment = .gravity` (see `ARPointCloudSession`),
/// not `.gravityAndHeading`, so there is no compass/heading reference baked
/// into the session at all. The new Y axis points wherever the camera
/// happened to face when tracking started — **not** true or grid north.
/// Anything that consumes this converted frame as if it were a real
/// geographic/projected CRS with a meaningful horizontal orientation would
/// be asserting something Pro Scan never actually measured.
///
/// Only `LASExporter` applies this — the one Pro Scan format explicitly
/// aimed at civil/survey tooling. `PLYExporter` deliberately does not: it
/// stays in ARKit's native frame for the in-app SceneKit viewer
/// (`PointCloudSceneView`) and for axis-convention-agnostic tools like
/// CloudCompare/MeshLab, neither of which benefit from the rotation.
enum TopographicAxisConvention {
    static func convert(_ arkitPosition: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(arkitPosition.x, -arkitPosition.z, arkitPosition.y)
    }

    /// Normals rotate the same way positions do — no translation component
    /// to account for either way.
    static func convertNormal(_ arkitNormal: SIMD3<Float>) -> SIMD3<Float> {
        convert(arkitNormal)
    }
}
