import XCTest
import simd

/// Verifies the filter that thins LiDAR scatter — and, just as importantly,
/// that it refuses to act where acting would invent geometry.
///
/// Every fixture here is a surface whose correct answer is known
/// analytically (a plane at a known offset, a right-angle corner, a sphere),
/// so "did it flatten the noise without flattening the shape" is a
/// measurement rather than a judgement call.
final class PointCloudDenoiserTests: XCTestCase {

    private func point(_ p: SIMD3<Float>, normal: SIMD3<Float> = SIMD3<Float>(0, 0, 1)) -> PointCloudExportPoint {
        PointCloudExportPoint(position: p, confidence: 1, color: SIMD3<Float>(1, 1, 1), normal: normal)
    }

    /// Deterministic pseudo-noise, so a failure is reproducible rather than
    /// a once-in-a-while flake.
    private struct Noise {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next(_ amplitude: Float) -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Float((state >> 33) % 10_000) / 10_000 * 2 - 1
            return unit * amplitude
        }
    }

    /// A wall in the z = 0 plane, sampled on a grid, with noise injected
    /// along the normal — exactly the shape LiDAR scatter takes.
    private func noisyWall(noiseAmplitude: Float, seed: UInt64 = 42) -> [PointCloudExportPoint] {
        var noise = Noise(seed: seed)
        var points: [PointCloudExportPoint] = []
        for i in 0..<26 {
            for j in 0..<26 {
                let x = Float(i) * 0.02
                let y = Float(j) * 0.02
                points.append(point(SIMD3<Float>(x, y, noise.next(noiseAmplitude))))
            }
        }
        return points
    }

    /// Scatter along the surface normal, as a standard deviation.
    ///
    /// Deliberately not min-to-max: that is an outlier statistic, and this
    /// filter *by design* refuses to move any point further than its
    /// correction ceiling. The few samples out at the noise extremes
    /// therefore survive untouched — which is correct behaviour, not a
    /// failure — so a min/max measure could never improve no matter how
    /// well the bulk of the surface was flattened. Standard deviation is
    /// also the better match for what "looks flat" means on screen.
    private func scatter(of points: [PointCloudExportPoint]) -> Float {
        guard !points.isEmpty else { return 0 }
        let zs = points.map(\.position.z)
        let mean = zs.reduce(0, +) / Float(zs.count)
        let variance = zs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(zs.count)
        return variance.squareRoot()
    }

    /// Share of points lying within `band` of the true surface — the direct
    /// measure of "is the bulk of this a sheet rather than a slab".
    private func fraction(of points: [PointCloudExportPoint], within band: Float) -> Float {
        guard !points.isEmpty else { return 0 }
        let inside = points.filter { abs($0.position.z) <= band }.count
        return Float(inside) / Float(points.count)
    }

    // MARK: - Adelgazar una superficie plana

    func testAWallScatteredAlongItsNormalIsCollapsedOntoThePlane() {
        let noisy = noisyWall(noiseAmplitude: 0.02)
        let before = scatter(of: noisy)

        let result = PointCloudDenoiser.denoise(noisy)

        let after = scatter(of: result.points)
        XCTAssertGreaterThan(before, 0.008, "The fixture must actually be a slab, or this proves nothing.")
        XCTAssertLessThan(after, before / 3, "A flat surface must come back far thinner than it went in.")
        XCTAssertGreaterThan(result.flattenedCount, result.points.count * 3 / 4)
    }

    /// The visual claim, stated as a measurement: after denoising, the wall
    /// is a sheet a few millimetres thick rather than a slab centimetres
    /// thick — which is the difference between reading as a surface and
    /// reading as cotton wool.
    func testTheBulkOfAWallEndsUpWithinAFewMillimetresOfTheSurface() {
        let noisy = noisyWall(noiseAmplitude: 0.02)
        XCTAssertLessThan(
            fraction(of: noisy, within: 0.005), 0.3,
            "Before denoising, most of the fixture must be outside the band this is about to check."
        )

        let result = PointCloudDenoiser.denoise(noisy)

        XCTAssertGreaterThan(
            fraction(of: result.points, within: 0.005), 0.85,
            "After denoising, the overwhelming majority of a flat wall should sit within 5 mm of it."
        )
    }

    func testFlatteningKeepsThePointsWhereTheSurfaceActuallyIs() {
        let result = PointCloudDenoiser.denoise(noisyWall(noiseAmplitude: 0.02))

        // The true surface is z = 0; noise was symmetric around it, so the
        // denoised cloud must still sit there rather than drifting to one side.
        let meanZ = result.points.map(\.position.z).reduce(0, +) / Float(result.points.count)
        XCTAssertEqual(meanZ, 0, accuracy: 0.004, "Denoising must not translate the surface off its measured position.")
    }

    func testFlatteningDoesNotMovePointsAlongTheSurface() {
        let noisy = noisyWall(noiseAmplitude: 0.02)
        let result = PointCloudDenoiser.denoise(noisy)

        // Only the normal component should change: x/y extent is real
        // geometry and must survive untouched.
        let originalX = noisy.map(\.position.x)
        let denoisedX = result.points.map(\.position.x)
        XCTAssertEqual(denoisedX.min()!, originalX.min()!, accuracy: 0.005)
        XCTAssertEqual(denoisedX.max()!, originalX.max()!, accuracy: 0.005)
    }

    // MARK: - Negarse a inventar geometría

    /// The guard that matters most: a corner is two planes meeting, and
    /// flattening it into one would delete a real architectural feature —
    /// and quietly move a wall.
    func testARightAngleCornerIsNotFlattenedIntoASinglePlane() {
        var points: [PointCloudExportPoint] = []
        for i in 0..<26 {
            for j in 0..<26 {
                let a = Float(i) * 0.02
                let b = Float(j) * 0.02
                points.append(point(SIMD3<Float>(a, b, 0), normal: SIMD3<Float>(0, 0, 1)))
                points.append(point(SIMD3<Float>(0, b, a), normal: SIMD3<Float>(1, 0, 0)))
            }
        }

        let result = PointCloudDenoiser.denoise(points)

        // Both faces must still be present at their true extents.
        let onFirstFace = result.points.filter { $0.position.z > 0.3 }
        let onSecondFace = result.points.filter { $0.position.x > 0.3 }
        XCTAssertGreaterThan(onFirstFace.count, 100, "The corner's second face must survive.")
        XCTAssertGreaterThan(onSecondFace.count, 100, "The corner's first face must survive.")
    }

    private func sphere(radius: Float, samples: Int = 60) -> [PointCloudExportPoint] {
        var points: [PointCloudExportPoint] = []
        for i in 0..<samples {
            for j in 0..<samples {
                let theta = Float(i) / Float(samples) * .pi
                let phi = Float(j) / Float(samples) * 2 * .pi
                let p = SIMD3<Float>(
                    radius * sin(theta) * cos(phi),
                    radius * sin(theta) * sin(phi),
                    radius * cos(theta)
                )
                points.append(point(p, normal: simd_normalize(p)))
            }
        }
        return points
    }

    /// A large curved surface — a column, a vaulted ceiling — deviates from
    /// its local tangent plane by far more than the correction ceiling, so
    /// its shape must survive intact.
    func testALargeCurvedSurfaceKeepsItsShape() {
        let radius: Float = 0.6
        let result = PointCloudDenoiser.denoise(sphere(radius: radius))

        for moved in result.points {
            XCTAssertEqual(
                simd_length(moved.position), radius, accuracy: 0.01,
                "A gently curved surface must not be shaved into facets."
            )
        }
    }

    /// The documented limit of this filter, pinned rather than left implicit:
    /// curvature finer than `maximumCorrectionMeters` is indistinguishable
    /// from noise around a plane, so a tightly curved object *is* smoothed —
    /// but never by more than that ceiling. This test exists so the bound is
    /// a measured guarantee instead of a hope.
    func testTightCurvatureIsSmoothedButNeverBeyondTheCorrectionCeiling() {
        let radius: Float = 0.25
        let ceiling = PointCloudDenoiser.Options.default.maximumCorrectionMeters
        let result = PointCloudDenoiser.denoise(sphere(radius: radius))

        for moved in result.points {
            let drift = abs(simd_length(moved.position) - radius)
            XCTAssertLessThanOrEqual(
                drift, ceiling + 0.001,
                "No point may be relocated further than the filter's stated ceiling."
            )
        }
    }

    /// A point far from any plane is not noise around that plane; relocating
    /// it would move real geometry rather than tighten a measurement.
    func testAPointTooFarFromTheFittedPlaneIsLeftWhereItWasMeasured() {
        var points = noisyWall(noiseAmplitude: 0.005)
        // A protrusion well beyond the correction ceiling, with enough
        // company to not be dismissed as an isolated flier.
        let spikeZ: Float = 0.30
        for i in 0..<10 {
            points.append(point(SIMD3<Float>(0.24 + Float(i) * 0.004, 0.24, spikeZ)))
        }

        let result = PointCloudDenoiser.denoise(points)

        let survivingSpike = result.points.filter { $0.position.z > 0.25 }
        XCTAssertEqual(survivingSpike.count, 10, "Geometry beyond the correction ceiling must be kept as measured.")
    }

    // MARK: - Puntos aislados

    func testIsolatedFliersAreRemoved() {
        var points = noisyWall(noiseAmplitude: 0.005)
        let wallCount = points.count
        // Stray returns far from any surface, each alone in space.
        for i in 0..<5 {
            points.append(point(SIMD3<Float>(3 + Float(i), 3, 3)))
        }

        let result = PointCloudDenoiser.denoise(points)

        XCTAssertEqual(result.removedCount, 5)
        XCTAssertEqual(result.points.count, wallCount)
    }

    func testNonFinitePointsAreDropped() {
        var points = noisyWall(noiseAmplitude: 0.005)
        points.append(point(SIMD3<Float>(.nan, 0, 0)))
        points.append(point(SIMD3<Float>(0, .infinity, 0)))

        let result = PointCloudDenoiser.denoise(points)

        XCTAssertFalse(result.points.contains { !$0.position.x.isFinite || !$0.position.y.isFinite || !$0.position.z.isFinite })
    }

    // MARK: - Contabilidad honesta

    func testEveryPointIsAccountedForInTheReportedCounts() {
        let points = noisyWall(noiseAmplitude: 0.02)

        let result = PointCloudDenoiser.denoise(points)

        XCTAssertEqual(
            result.flattenedCount + result.untouchedCount + result.removedCount,
            points.count,
            "The reported counts are shown to the user; they have to add up to the input."
        )
        XCTAssertEqual(result.flattenedCount + result.untouchedCount, result.points.count)
    }

    func testAColorAndConfidenceSurviveFlattening() {
        let original = PointCloudExportPoint(
            position: SIMD3<Float>(0.2, 0.2, 0.01),
            confidence: 0.75,
            color: SIMD3<Float>(0.1, 0.9, 0.3),
            normal: SIMD3<Float>(0, 0, 1)
        )
        var points = noisyWall(noiseAmplitude: 0.01)
        points.append(original)

        let result = PointCloudDenoiser.denoise(points)

        let match = result.points.first { $0.confidence == 0.75 }
        XCTAssertNotNil(match, "Denoising adjusts position, it must not discard a point's measured attributes.")
        XCTAssertEqual(match?.color.y ?? 0, 0.9, accuracy: 1e-5)
    }

    // MARK: - Bloques internos

    func testFitPlaneRecoversAKnownPlane() throws {
        // Plane z = 0.5, normal along +/- z.
        var positions: [SIMD3<Float>] = []
        for i in 0..<6 {
            for j in 0..<6 {
                positions.append(SIMD3<Float>(Float(i) * 0.1, Float(j) * 0.1, 0.5))
            }
        }

        let plane = try XCTUnwrap(PointCloudDenoiser.fitPlane(to: positions))

        XCTAssertEqual(abs(plane.normal.z), 1, accuracy: 1e-3)
        XCTAssertEqual(plane.centroid.z, 0.5, accuracy: 1e-5)
        XCTAssertLessThan(plane.thicknessMeters, 1e-4, "A perfect plane has no thickness.")
        XCTAssertLessThan(plane.flatnessRatio, 1e-4)
    }

    func testFitPlaneReportsAHighResidualForABlob() throws {
        var positions: [SIMD3<Float>] = []
        var noise = Noise(seed: 7)
        for _ in 0..<200 {
            positions.append(SIMD3<Float>(noise.next(1), noise.next(1), noise.next(1)))
        }

        let plane = try XCTUnwrap(PointCloudDenoiser.fitPlane(to: positions))

        XCTAssertGreaterThan(plane.flatnessRatio, 0.4, "An isotropic cloud must not pass as a plane.")
    }

    func testEigenDecompositionOfADiagonalMatrixReturnsItsDiagonal() {
        let matrix = simd_float3x3(
            SIMD3<Float>(3, 0, 0),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(0, 0, 2)
        )

        let (values, _) = PointCloudDenoiser.symmetricEigenDecomposition(matrix)

        XCTAssertEqual([values.x, values.y, values.z].sorted().map { round($0) }, [1, 2, 3])
    }

    func testDenoisingATinyCloudIsANoOpRatherThanAnError() {
        let points = [point(SIMD3<Float>(0, 0, 0)), point(SIMD3<Float>(1, 0, 0))]

        let result = PointCloudDenoiser.denoise(points)

        XCTAssertEqual(result.points.count, 2)
        XCTAssertEqual(result.untouchedCount, 2)
    }
}
