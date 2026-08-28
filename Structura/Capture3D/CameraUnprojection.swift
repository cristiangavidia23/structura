import CoreGraphics
import simd

/// The pinhole camera math Pro Scan's two capture pipelines both need:
/// rescaling ARKit's calibrated intrinsics to a smaller buffer's
/// resolution, unprojecting an image pixel + depth into a 3D point, and the
/// inverse (reprojecting a 3D point back onto the image to sample its
/// color). Pure Swift/simd, no ARKit dependency — deliberately, so it
/// compiles into the host-less `StructuraTests` logic-test target without
/// linking the framework, and so every branch here has a synthetic-data
/// test (`CameraUnprojectionTests`).
///
/// Coordinate systems (the assumption every function below leans on):
/// ARKit's camera space is **right-handed, +Y up**, with the camera
/// looking down its own **-Z** axis (`ARCamera.transform`/`ARFrame`,
/// Apple's documented convention — the same space `ProScanConfig`'s doc
/// comment describes for the pipeline as a whole). `ARCamera.intrinsics`,
/// by contrast, is calibrated against **image-space pixels**: origin
/// top-left, +X right, +Y **down**. Converting between the two means the
/// image's Y axis must be *negated* relative to camera-space Y — moving
/// toward the bottom of the image (+Y in image space) corresponds to
/// moving *down* in the real world (-Y in camera space). X needs no such
/// flip: it points right in both conventions. Z only exists in camera
/// space, as the negative of the pixel's forward depth (the camera looks
/// down -Z).
///
/// (A downstream export target that is +Z up, as some CAD/GIS tooling
/// assumes, is a *different* conversion applied at the export boundary —
/// see `Export/PointCloud` — and is unrelated to the image/camera-space
/// flip handled here.)
enum CameraUnprojection {

    /// A pinhole camera's focal lengths and principal point, calibrated
    /// against some specific pixel resolution. Plain floats rather than
    /// `simd_float3x3` at the call sites, so callers don't need to know or
    /// care which matrix cell means what.
    struct Intrinsics {
        var fx: Float
        var fy: Float
        var cx: Float
        var cy: Float

        /// `ARCamera.intrinsics` is a `simd_float3x3` in column-major form
        /// `[[fx,0,0],[0,fy,0],[cx,cy,1]]` — `matrix[0][0]` is `fx`,
        /// `matrix[1][1]` is `fy`, and the principal point lives in the
        /// third column (`matrix[2][0]`, `matrix[2][1]`).
        init(_ matrix: simd_float3x3) {
            fx = matrix[0][0]
            fy = matrix[1][1]
            cx = matrix[2][0]
            cy = matrix[2][1]
        }

        init(fx: Float, fy: Float, cx: Float, cy: Float) {
            self.fx = fx
            self.fy = fy
            self.cx = cx
            self.cy = cy
        }
    }

    /// Rescales intrinsics calibrated for one image resolution to another
    /// (e.g. `ARCamera.intrinsics`, calibrated for the full-resolution
    /// color image at ~1920x1440, down to the scene-depth map's much
    /// smaller ~256x192) — using the intrinsics unscaled against the
    /// smaller buffer's pixel coordinates puts the optical center far off
    /// and throws every unprojected point outside the view frustum.
    /// Assumes uniform scaling: both resolutions share the same aspect
    /// ratio and orientation, which holds for ARKit's own depth/color
    /// buffer pairing.
    static func rescale(_ intrinsics: Intrinsics, from: CGSize, to: CGSize) -> Intrinsics {
        let scaleX = Float(to.width) / Float(from.width)
        let scaleY = Float(to.height) / Float(from.height)
        return Intrinsics(
            fx: intrinsics.fx * scaleX,
            fy: intrinsics.fy * scaleY,
            cx: intrinsics.cx * scaleX,
            cy: intrinsics.cy * scaleY
        )
    }

    /// Unprojects an image-space pixel (origin top-left, +Y down) at a
    /// known forward depth into ARKit camera space (+Y up, looking down
    /// -Z). `depth` is the sensor's forward distance and should be
    /// positive — this function does not itself validate range or
    /// finiteness; see `ProScanConfig.isDepthValid`.
    static func unproject(pixel: SIMD2<Float>, depth: Float, intrinsics: Intrinsics) -> SIMD3<Float> {
        let x = (pixel.x - intrinsics.cx) * depth / intrinsics.fx
        let y = -(pixel.y - intrinsics.cy) * depth / intrinsics.fy
        return SIMD3<Float>(x, y, -depth)
    }

    /// The inverse of `unproject`: projects a camera-space point back onto
    /// the image plane. Returns `nil` for points at or behind the camera
    /// (non-positive forward depth), since those have no meaningful pixel.
    static func project(cameraSpacePoint: SIMD3<Float>, intrinsics: Intrinsics) -> SIMD2<Float>? {
        let depth = -cameraSpacePoint.z
        guard depth > 0 else { return nil }
        let x = cameraSpacePoint.x * intrinsics.fx / depth + intrinsics.cx
        let y = -cameraSpacePoint.y * intrinsics.fy / depth + intrinsics.cy
        return SIMD2<Float>(x, y)
    }
}
