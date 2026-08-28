import CoreLocation

/// One-shot, fully optional location fetch for point-cloud export metadata.
/// Requests when-in-use authorization on demand if not yet determined, and
/// never blocks or fails the export: a denied/unavailable permission simply
/// yields `nil`.
///
/// `Info.plist` must declare `NSLocationWhenInUseUsageDescription` for the
/// authorization prompt to appear at all. Before this fix, nothing here
/// ever called `requestWhenInUseAuthorization()` — the status stayed
/// `.notDetermined` forever and every call returned `nil` regardless of
/// what the user might have chosen, making location capture dead code.
final class PointCloudLocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authorizationContinuation: CheckedContinuation<Void, Never>?
    private var locationContinuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    func requestLocation() async -> CLLocationCoordinate2D? {
        manager.delegate = self

        if manager.authorizationStatus == .notDetermined {
            await withCheckedContinuation { continuation in
                self.authorizationContinuation = continuation
                manager.requestWhenInUseAuthorization()
            }
        }

        guard manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            self.locationContinuation = continuation
            manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationContinuation?.resume()
        authorizationContinuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        locationContinuation?.resume(returning: locations.first?.coordinate)
        locationContinuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationContinuation?.resume(returning: nil)
        locationContinuation = nil
    }
}
