import Foundation
import simd

/// Owns in-progress measurement state for `PointCloudSceneView`: the two
/// tapped points (if any), whether each snapped to a plane, the resulting
/// distance, and calibration state. A plain `ObservableObject` rather than
/// state baked into the view itself, so the surrounding SwiftUI overlay
/// (distance readout, "Calibrar" button) can observe and act on it
/// independently of the `UIViewRepresentable` that owns the actual
/// SceneKit gesture handling.
@MainActor
final class MeasurementSession: ObservableObject {
    struct MeasuredPoint: Equatable {
        var position: SIMD3<Float>
        var didSnapToPlane: Bool
    }

    @Published private(set) var firstPoint: MeasuredPoint?
    @Published private(set) var secondPoint: MeasuredPoint?
    @Published var isPresentingCalibration = false
    @Published private(set) var calibrationResult: MeasurementCalibration.Result?

    var distanceMeters: Float? {
        guard let firstPoint, let secondPoint else { return nil }
        return simd_distance(firstPoint.position, secondPoint.position)
    }

    /// Both points came from a plane snap — the case where a calibration
    /// check is most meaningful, since an unsnapped raw point carries
    /// whatever noise the individual sample had.
    var bothPointsSnapped: Bool {
        (firstPoint?.didSnapToPlane ?? false) && (secondPoint?.didSnapToPlane ?? false)
    }

    /// A tap when both points are already set starts a fresh measurement
    /// rather than endlessly accumulating — matches how the Measure app
    /// and similar tools behave.
    func addTappedPoint(_ point: MeasuredPoint) {
        if firstPoint == nil {
            firstPoint = point
        } else if secondPoint == nil {
            secondPoint = point
        } else {
            firstPoint = point
            secondPoint = nil
            calibrationResult = nil
        }
    }

    func clear() {
        firstPoint = nil
        secondPoint = nil
        calibrationResult = nil
        isPresentingCalibration = false
    }

    func calibrate(referenceMeters: Float) {
        guard let distanceMeters else { return }
        calibrationResult = MeasurementCalibration.evaluate(measuredMeters: distanceMeters, referenceMeters: referenceMeters)
    }
}
