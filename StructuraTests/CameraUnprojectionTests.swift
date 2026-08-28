import CoreGraphics
import simd
import XCTest

/// Numeric acceptance tests for `CameraUnprojection`, per the Pro Scan
/// audit's Fase 1 verification plan. Each test targets a distinct failure
/// mode rather than re-deriving the module's own formulas as the "expected"
/// value — doing that would let a bug shared between generation and
/// verification cancel out and pass silently:
///
/// - `testPixelAboveCenterUnprojectsToPositiveCameraY` checks the raw axis
///   convention directly. This is the one that would have failed before the
///   missing-Y-negation fix landed (the pre-fix code produced a *negative*
///   Y here, mirroring the scene vertically).
/// - `testUnprojectThenProjectRoundTrips` checks internal self-consistency
///   between the two directions — necessary, but not sufficient on its own,
///   since a bug that flips both directions identically could still round-
///   trip correctly while being wrong relative to the real world.
/// - The two plane tests build synthetic depth data from an independently
///   written ray-plane intersection oracle (`oracleDepth`, below) — never by
///   calling `CameraUnprojection.project` — so a bug shared between the two
///   can't hide.
final class CameraUnprojectionTests: XCTestCase {

    /// A plausible ARKit depth-camera intrinsics/resolution pairing (the
    /// LiDAR scene-depth map is roughly 256x192). The exact numbers don't
    /// matter for these tests, only that fx/fy/cx/cy are self-consistent
    /// with the stated resolution.
    private let intrinsics = CameraUnprojection.Intrinsics(fx: 210, fy: 210, cx: 128, cy: 96)

    // MARK: - Axis convention (the actual Y-sign bug this fase fixes)

    func testPixelAboveCenterUnprojectsToPositiveCameraY() {
        // A pixel row above the principal point (smaller y — image space is
        // +Y down) must land at positive Y in ARKit's +Y-up camera space:
        // physically "higher in the image" must mean "higher in the world".
        let pixelAboveCenter = SIMD2<Float>(intrinsics.cx, intrinsics.cy - 40)
        let point = CameraUnprojection.unproject(pixel: pixelAboveCenter, depth: 2.0, intrinsics: intrinsics)
        XCTAssertGreaterThan(point.y, 0, "A pixel above the principal point must unproject to positive camera-space Y.")
    }

    func testPixelBelowCenterUnprojectsToNegativeCameraY() {
        let pixelBelowCenter = SIMD2<Float>(intrinsics.cx, intrinsics.cy + 40)
        let point = CameraUnprojection.unproject(pixel: pixelBelowCenter, depth: 2.0, intrinsics: intrinsics)
        XCTAssertLessThan(point.y, 0)
    }

    func testPrincipalPointUnprojectsOnCameraAxis() {
        let point = CameraUnprojection.unproject(pixel: SIMD2<Float>(intrinsics.cx, intrinsics.cy), depth: 3.0, intrinsics: intrinsics)
        XCTAssertEqual(point.x, 0, accuracy: 1e-4)
        XCTAssertEqual(point.y, 0, accuracy: 1e-4)
        XCTAssertEqual(point.z, -3.0, accuracy: 1e-4)
    }

    // MARK: - Round trip

    func testUnprojectThenProjectRoundTrips() {
        let testPixels: [SIMD2<Float>] = [
            SIMD2(40, 30), SIMD2(128, 96), SIMD2(200, 20), SIMD2(10, 170), SIMD2(220, 180),
        ]
        for pixel in testPixels {
            let point = CameraUnprojection.unproject(pixel: pixel, depth: 1.8, intrinsics: intrinsics)
            guard let reprojected = CameraUnprojection.project(cameraSpacePoint: point, intrinsics: intrinsics) else {
                XCTFail("Round trip should never land behind the camera for a point unprojected at positive depth.")
                continue
            }
            XCTAssertEqual(reprojected.x, pixel.x, accuracy: 0.01, "Round-trip pixel.x drifted for \(pixel)")
            XCTAssertEqual(reprojected.y, pixel.y, accuracy: 0.01, "Round-trip pixel.y drifted for \(pixel)")
        }
    }

    func testProjectReturnsNilBehindCamera() {
        let behindCamera = SIMD3<Float>(0, 0, 1) // +Z is behind an ARKit camera (which looks down -Z)
        XCTAssertNil(CameraUnprojection.project(cameraSpacePoint: behindCamera, intrinsics: intrinsics))
    }

    // MARK: - Intrinsics rescaling

    func testRescaleScalesFocalLengthAndPrincipalPointUniformly() {
        let full = CameraUnprojection.Intrinsics(fx: 1600, fy: 1600, cx: 960, cy: 720)
        let fullResolution = CGSize(width: 1920, height: 1440)
        let depthResolution = CGSize(width: 256, height: 192)
        let scaled = CameraUnprojection.rescale(full, from: fullResolution, to: depthResolution)

        let expectedScale: Float = 256.0 / 1920.0 // depth map / color image, same aspect ratio
        XCTAssertEqual(scaled.fx, full.fx * expectedScale, accuracy: 0.01)
        XCTAssertEqual(scaled.fy, full.fy * expectedScale, accuracy: 0.01)
        XCTAssertEqual(scaled.cx, full.cx * expectedScale, accuracy: 0.01)
        XCTAssertEqual(scaled.cy, full.cy * expectedScale, accuracy: 0.01)
    }

    // MARK: - Synthetic plane reconstruction

    /// A frontoparallel plane produces a *constant* depth map (every pixel
    /// on the plane is the same forward distance from the camera) — no
    /// projection math is needed to generate the synthetic input, so this
    /// specifically checks that reconstruction doesn't introduce any
    /// per-pixel drift as it sweeps across the image, independent of the
    /// axis-sign question the tests above already cover.
    func testFrontoparallelPlaneReconstructsWithSubMillimeterRMS() {
        let planeDepth: Float = 2.000
        var squaredErrors: [Float] = []

        for row in stride(from: 10, to: 190, by: 10) {
            for col in stride(from: 10, to: 250, by: 10) {
                let pixel = SIMD2<Float>(Float(col), Float(row))
                let point = CameraUnprojection.unproject(pixel: pixel, depth: planeDepth, intrinsics: intrinsics)
                let error = point.z - (-planeDepth) // signed distance to the known plane z = -planeDepth
                squaredErrors.append(error * error)
            }
        }

        let rms = sqrt(squaredErrors.reduce(0, +) / Float(squaredErrors.count))
        XCTAssertLessThan(rms, 0.001, "RMS distance to the known frontoparallel plane must stay under 1 mm.")
    }

    /// A plane tilted 30° about the camera's X axis: normal =
    /// (0, sin(30°), cos(30°)) in ARKit camera space, passing through
    /// (0, 0, -2). Depth values come from `oracleDepth` below — an
    /// independent ray-plane intersection, *not* a call into
    /// `CameraUnprojection` — so a bug shared between generation and
    /// reconstruction can't cancel out and hide.
    func testTiltedPlaneRecoversNormalAndFitsWithSubMillimeterRMS() {
        let tiltRadians: Float = 30 * .pi / 180
        let expectedNormal = simd_normalize(SIMD3<Float>(0, sin(tiltRadians), cos(tiltRadians)))
        let pointOnPlane = SIMD3<Float>(0, 0, -2)

        var reconstructed: [SIMD3<Float>] = []
        for row in stride(from: 20, to: 180, by: 20) {
            for col in stride(from: 20, to: 240, by: 20) {
                let pixel = SIMD2<Float>(Float(col), Float(row))
                guard let depth = Self.oracleDepth(
                    forPixel: pixel, intrinsics: intrinsics,
                    planeNormal: expectedNormal, pointOnPlane: pointOnPlane
                ) else { continue }
                reconstructed.append(CameraUnprojection.unproject(pixel: pixel, depth: depth, intrinsics: intrinsics))
            }
        }
        XCTAssertGreaterThan(reconstructed.count, 20, "Expected the sampled grid to yield enough in-frustum points to test.")

        // RMS signed distance of every reconstructed point to the *known*
        // plane (not an independently fitted one — with zero synthetic
        // noise the two coincide, which avoids needing a PCA/eigen-solver
        // just for this unit test).
        let squaredErrors = reconstructed.map { point -> Float in
            let d = simd_dot(point - pointOnPlane, expectedNormal)
            return d * d
        }
        let rms = sqrt(squaredErrors.reduce(0, +) / Float(squaredErrors.count))
        XCTAssertLessThan(rms, 0.001, "RMS distance to the known tilted plane must stay under 1 mm.")

        // Independently estimate the normal from three well-separated
        // reconstructed points — three non-collinear points exactly
        // determine a plane, so with zero synthetic noise this recovers
        // the true normal up to floating-point epsilon if (and only if)
        // reconstruction is correct.
        let a = reconstructed[0]
        let b = reconstructed[reconstructed.count / 2]
        let c = reconstructed[reconstructed.count - 1]
        let empiricalNormal = simd_normalize(simd_cross(b - a, c - a))
        let cosAngle = abs(simd_dot(empiricalNormal, expectedNormal)) // abs: cross-product sign is arbitrary
        let angleErrorDegrees = acos(min(1, cosAngle)) * 180 / .pi
        XCTAssertLessThan(angleErrorDegrees, 0.1, "Recovered plane normal must be within 0.1° of the expected tilt.")
    }

    /// Independent ray-plane intersection oracle: for a pixel's viewing ray
    /// (written here from first principles, in the same image/camera-space
    /// convention `CameraUnprojection` uses — but never by calling it),
    /// finds the forward depth at which that ray hits the given plane.
    /// Returns `nil` if the ray is parallel to the plane or would hit
    /// behind the camera.
    private static func oracleDepth(
        forPixel pixel: SIMD2<Float>,
        intrinsics: CameraUnprojection.Intrinsics,
        planeNormal: SIMD3<Float>,
        pointOnPlane: SIMD3<Float>
    ) -> Float? {
        // Ray direction at unit forward-depth: image +Y down flips to
        // camera-space -Y, and the camera looks down -Z.
        let directionAtUnitDepth = SIMD3<Float>(
            (pixel.x - intrinsics.cx) / intrinsics.fx,
            -(pixel.y - intrinsics.cy) / intrinsics.fy,
            -1
        )
        // A camera-space point at forward depth d is
        // `directionAtUnitDepth * d` (the ray originates at the camera
        // center). Solve n·(P - p0) = 0 for d.
        let denominator = simd_dot(planeNormal, directionAtUnitDepth)
        guard abs(denominator) > 1e-6 else { return nil }
        let d = simd_dot(planeNormal, pointOnPlane) / denominator
        guard d > 0 else { return nil }
        return d
    }
}
