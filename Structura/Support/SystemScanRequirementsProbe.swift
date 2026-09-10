import ARKit
import AVFoundation
import UIKit

/// The real answers behind `ScanRequirementsProviding`: what this device can
/// do, and what the user has allowed.
///
/// Isolated in its own file precisely because it imports ARKit and
/// AVFoundation — keeping those imports out of `ScanRequirements` and
/// `ScanRequirementsModel` is what lets the decision logic be tested without
/// a device or an app host.
struct SystemScanRequirementsProbe: ScanRequirementsProviding {

    /// Scene depth is the capability Pro Scan actually depends on, so it is
    /// the honest thing to test for — rather than matching model names, which
    /// would need editing every time Apple ships a new device.
    ///
    /// Note on distribution: `project.yml` also declares `lidar` under
    /// `UIRequiredDeviceCapabilities`, so the App Store will not install
    /// Structura on a device without it and this check should never fail in
    /// production. It is kept as a real gate anyway — it costs nothing, it
    /// covers development builds and TestFlight on mixed hardware, and if
    /// that capability declaration is ever relaxed to widen distribution,
    /// this is what stops a non-LiDAR device from reaching a capture screen
    /// that cannot work.
    var hasLiDAR: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    var cameraAuthorization: ScanRequirements.CameraAuthorization {
        Self.map(AVCaptureDevice.authorizationStatus(for: .video))
    }

    func requestCameraAccess() async -> ScanRequirements.CameraAuthorization {
        // Ask, then re-read rather than trusting the returned `Bool`: the
        // status is what the rest of the app reasons about, and a granted/
        // denied boolean cannot express `.restricted`.
        _ = await AVCaptureDevice.requestAccess(for: .video)
        return cameraAuthorization
    }

    private static func map(_ status: AVAuthorizationStatus) -> ScanRequirements.CameraAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        // A status this app doesn't recognize is treated as "not usable, and
        // not something we should offer to fix" — the conservative reading.
        @unknown default: return .restricted
        }
    }
}

extension ScanRequirements.State {
    /// Opens Structura's own page in Settings, where the camera switch is.
    ///
    /// Guarded by `offersSettingsShortcut` so it can't be wired to a state
    /// where Settings wouldn't help (`.cameraRestricted`).
    @MainActor
    func openSettings() {
        guard offersSettingsShortcut,
              let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }
}
