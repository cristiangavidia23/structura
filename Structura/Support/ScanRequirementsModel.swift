import Observation

/// Observable gate the app consults before letting anyone into a capture
/// flow: hardware first, then camera permission.
///
/// Holds its provider behind `ScanRequirementsProviding` and imports no
/// capture frameworks itself, so this type — the one with the actual state
/// transitions — compiles into the host-less test target and can be driven
/// through every state with a fake. The real hardware queries live in
/// `SystemScanRequirementsProbe`.
@Observable
@MainActor
final class ScanRequirementsModel {

    private(set) var state: ScanRequirements.State

    /// `true` while the system permission prompt is on screen, so the UI can
    /// disable its own button instead of letting a second tap stack another
    /// request behind the first.
    private(set) var isRequestingCameraAccess = false

    @ObservationIgnored private let provider: ScanRequirementsProviding

    init(provider: ScanRequirementsProviding) {
        self.provider = provider
        self.state = ScanRequirements.state(
            for: ScanRequirements.Environment(
                hasLiDAR: provider.hasLiDAR,
                camera: provider.cameraAuthorization
            )
        )
    }

    /// Re-reads the environment.
    ///
    /// Needed on every return to the foreground, not just at launch: the user
    /// can leave for Settings, flip the camera switch, and come back — and
    /// iOS does not notify the app when they do. Without this the app would
    /// keep showing "permission denied" over a permission that is now
    /// granted.
    func refresh() {
        state = ScanRequirements.state(
            for: ScanRequirements.Environment(
                hasLiDAR: provider.hasLiDAR,
                camera: provider.cameraAuthorization
            )
        )
    }

    /// Presents the system prompt, then re-derives the state from the answer.
    ///
    /// Only does anything in `.awaitingCameraPermission`. Calling it once the
    /// user has already answered is a no-op by design: iOS will not re-prompt
    /// after a denial, so a button that appeared to ask again — and silently
    /// did nothing — would be worse than one that sends the user to Settings.
    func requestCameraAccess() async {
        guard state == .awaitingCameraPermission, !isRequestingCameraAccess else { return }
        isRequestingCameraAccess = true
        let authorization = await provider.requestCameraAccess()
        isRequestingCameraAccess = false

        state = ScanRequirements.state(
            for: ScanRequirements.Environment(hasLiDAR: provider.hasLiDAR, camera: authorization)
        )
    }
}
