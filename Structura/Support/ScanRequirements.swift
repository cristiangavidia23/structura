import Foundation

/// What Structura needs before it can scan anything, and what to show the
/// user when one of those things is missing.
///
/// Deliberately free of ARKit and AVFoundation: the decision of *what state
/// we are in* is pure logic over two inputs, and keeping it that way is what
/// lets it compile into the host-less `StructuraTests` target and be tested
/// exhaustively without a device — the same separation the rest of the
/// project applies between capture math and ARKit. The types that actually
/// interrogate the hardware live in `SystemScanRequirementsProbe`.
enum ScanRequirements {

    /// Camera authorization, mirrored into a local type rather than passing
    /// `AVAuthorizationStatus` around. Two reasons: this file stays
    /// framework-free, and the two cases AVFoundation lumps together as "not
    /// usable" (`denied` and `restricted`) need genuinely different UI —
    /// only one of them is something the user can fix.
    enum CameraAuthorization: Equatable {
        /// Never asked. The app may present its own explanation and then ask.
        case notDetermined
        case authorized
        /// The user said no. Recoverable, but only through Settings — iOS
        /// will not show the system prompt a second time.
        case denied
        /// Blocked by policy (parental controls, MDM). The user cannot grant
        /// it themselves, so offering a Settings shortcut would be a dead end.
        case restricted
    }

    struct Environment: Equatable {
        /// Whether this device has the depth hardware Pro Scan needs.
        var hasLiDAR: Bool
        var camera: CameraAuthorization

        init(hasLiDAR: Bool, camera: CameraAuthorization) {
            self.hasLiDAR = hasLiDAR
            self.camera = camera
        }
    }

    /// The single thing the UI switches on.
    enum State: Equatable {
        /// No LiDAR: nothing in this app works, and no permission changes it.
        case unsupportedDevice
        /// Hardware is fine and we may still ask for the camera.
        case awaitingCameraPermission
        /// Asked and refused. Recoverable through Settings.
        case cameraDenied
        /// Refused by policy; the user cannot change it.
        case cameraRestricted
        case ready

        /// Whether scanning can proceed. Everything else is a blocking state
        /// with its own explanatory screen.
        var canScan: Bool { self == .ready }

        /// Whether the app should offer a shortcut into Settings — true only
        /// where going there would actually let the user fix it. Offering it
        /// for `.cameraRestricted` would send someone to a switch they are
        /// not allowed to flip.
        var offersSettingsShortcut: Bool { self == .cameraDenied }
    }

    /// Hardware is checked before permissions on purpose: on a device without
    /// LiDAR the camera permission is irrelevant, and asking for it would
    /// take the user through a prompt that grants access to an app that
    /// still cannot do anything.
    static func state(for environment: Environment) -> State {
        guard environment.hasLiDAR else { return .unsupportedDevice }

        switch environment.camera {
        case .authorized: return .ready
        case .notDetermined: return .awaitingCameraPermission
        case .denied: return .cameraDenied
        case .restricted: return .cameraRestricted
        }
    }
}

/// Supplies the live values `ScanRequirements.state(for:)` reasons about.
///
/// A protocol rather than direct calls so tests can drive every state from a
/// fake, and so SwiftUI previews can render the unsupported-device and
/// permission-denied screens on a machine where the real answers are always
/// "supported" and "authorized".
protocol ScanRequirementsProviding {
    var hasLiDAR: Bool { get }
    var cameraAuthorization: ScanRequirements.CameraAuthorization { get }
    /// Presents the system permission prompt, returning the resulting
    /// authorization. Only meaningful in `.notDetermined`; iOS ignores
    /// further requests once the user has answered once.
    func requestCameraAccess() async -> ScanRequirements.CameraAuthorization
}
