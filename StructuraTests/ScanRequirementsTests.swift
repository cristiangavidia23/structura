import XCTest

/// Covers the gate that decides whether anyone gets to a capture screen.
///
/// Testable without a device or an app host precisely because the decision
/// and the model were kept free of ARKit/AVFoundation — the real hardware
/// queries live in `SystemScanRequirementsProbe`, which is not part of this
/// target. What is exercised here is every combination the app can actually
/// find itself in, including the ones that are hard to reproduce by hand on
/// real hardware (no LiDAR, camera restricted by policy).
final class ScanRequirementsTests: XCTestCase {

    /// Drives the model through states a real device would not reproduce on
    /// demand, and records whether the system prompt was reached.
    private final class FakeProvider: ScanRequirementsProviding, @unchecked Sendable {
        var hasLiDAR: Bool
        var cameraAuthorization: ScanRequirements.CameraAuthorization
        /// What the simulated system prompt returns.
        var authorizationAfterRequest: ScanRequirements.CameraAuthorization
        private(set) var requestCount = 0

        init(
            hasLiDAR: Bool = true,
            cameraAuthorization: ScanRequirements.CameraAuthorization = .notDetermined,
            authorizationAfterRequest: ScanRequirements.CameraAuthorization = .authorized
        ) {
            self.hasLiDAR = hasLiDAR
            self.cameraAuthorization = cameraAuthorization
            self.authorizationAfterRequest = authorizationAfterRequest
        }

        func requestCameraAccess() async -> ScanRequirements.CameraAuthorization {
            requestCount += 1
            cameraAuthorization = authorizationAfterRequest
            return authorizationAfterRequest
        }
    }

    private func state(hasLiDAR: Bool, camera: ScanRequirements.CameraAuthorization) -> ScanRequirements.State {
        ScanRequirements.state(for: .init(hasLiDAR: hasLiDAR, camera: camera))
    }

    // MARK: - Decisión de estado

    func testEveryCameraStateMapsToItsOwnBlockingStateOnCapableHardware() {
        XCTAssertEqual(state(hasLiDAR: true, camera: .authorized), .ready)
        XCTAssertEqual(state(hasLiDAR: true, camera: .notDetermined), .awaitingCameraPermission)
        XCTAssertEqual(state(hasLiDAR: true, camera: .denied), .cameraDenied)
        // Denied and restricted must not collapse into one state: only one of
        // them is something the user can fix.
        XCTAssertEqual(state(hasLiDAR: true, camera: .restricted), .cameraRestricted)
    }

    /// Missing hardware outranks permissions: granting the camera on a device
    /// with no LiDAR would still leave the app unable to scan, so it must
    /// never be asked for.
    func testMissingLiDARBlocksRegardlessOfCameraAuthorization() {
        for camera: ScanRequirements.CameraAuthorization in [.notDetermined, .authorized, .denied, .restricted] {
            XCTAssertEqual(
                state(hasLiDAR: false, camera: camera),
                .unsupportedDevice,
                "A device without LiDAR is unsupported whatever the camera status (\(camera))."
            )
        }
    }

    // MARK: - Qué habilita cada estado

    func testOnlyReadyAllowsScanning() {
        XCTAssertTrue(ScanRequirements.State.ready.canScan)
        for blocked: ScanRequirements.State in [.unsupportedDevice, .awaitingCameraPermission, .cameraDenied, .cameraRestricted] {
            XCTAssertFalse(blocked.canScan, "\(blocked) must not let the user into a capture screen.")
        }
    }

    /// A Settings shortcut is only honest where Settings can fix it. Offering
    /// it under a policy restriction sends the user to a switch they are not
    /// allowed to change; offering it with no LiDAR implies the hardware is a
    /// setting.
    func testSettingsShortcutIsOfferedOnlyWhereItCanActuallyHelp() {
        XCTAssertTrue(ScanRequirements.State.cameraDenied.offersSettingsShortcut)
        for state: ScanRequirements.State in [.unsupportedDevice, .cameraRestricted, .awaitingCameraPermission, .ready] {
            XCTAssertFalse(state.offersSettingsShortcut, "\(state) must not offer a Settings shortcut.")
        }
    }

    // MARK: - Modelo

    @MainActor
    func testInitialStateIsDerivedFromTheProvider() {
        let model = ScanRequirementsModel(provider: FakeProvider(hasLiDAR: false))
        XCTAssertEqual(model.state, .unsupportedDevice)
    }

    @MainActor
    func testGrantingThePromptMovesTheModelToReady() async {
        let provider = FakeProvider(cameraAuthorization: .notDetermined, authorizationAfterRequest: .authorized)
        let model = ScanRequirementsModel(provider: provider)
        XCTAssertEqual(model.state, .awaitingCameraPermission)

        await model.requestCameraAccess()

        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(provider.requestCount, 1)
    }

    @MainActor
    func testRefusingThePromptLeavesARecoverableDeniedState() async {
        let provider = FakeProvider(cameraAuthorization: .notDetermined, authorizationAfterRequest: .denied)
        let model = ScanRequirementsModel(provider: provider)

        await model.requestCameraAccess()

        XCTAssertEqual(model.state, .cameraDenied)
        XCTAssertTrue(model.state.offersSettingsShortcut, "A refusal must leave the user a way back through Settings.")
    }

    /// iOS shows the permission prompt once and never again, so asking a
    /// second time would do nothing while looking like it did something.
    @MainActor
    func testAskingAgainAfterADenialDoesNotReachTheSystemPrompt() async {
        let provider = FakeProvider(cameraAuthorization: .denied)
        let model = ScanRequirementsModel(provider: provider)
        XCTAssertEqual(model.state, .cameraDenied)

        await model.requestCameraAccess()

        XCTAssertEqual(provider.requestCount, 0)
        XCTAssertEqual(model.state, .cameraDenied)
    }

    @MainActor
    func testPermissionIsNeverRequestedOnUnsupportedHardware() async {
        let provider = FakeProvider(hasLiDAR: false, cameraAuthorization: .notDetermined)
        let model = ScanRequirementsModel(provider: provider)

        await model.requestCameraAccess()

        XCTAssertEqual(provider.requestCount, 0, "An unsupported device must never see a camera prompt it has no use for.")
        XCTAssertEqual(model.state, .unsupportedDevice)
    }

    /// The Settings round trip: the app is backgrounded on `.cameraDenied`,
    /// the user flips the switch, and iOS says nothing on return — `refresh()`
    /// is the only thing that notices.
    @MainActor
    func testRefreshPicksUpAPermissionGrantedWhileTheAppWasBackgrounded() {
        let provider = FakeProvider(cameraAuthorization: .denied)
        let model = ScanRequirementsModel(provider: provider)
        XCTAssertEqual(model.state, .cameraDenied)

        provider.cameraAuthorization = .authorized
        XCTAssertEqual(model.state, .cameraDenied, "State must not change until it is re-read.")

        model.refresh()

        XCTAssertEqual(model.state, .ready)
    }

    /// The same round trip in reverse: permission revoked from Settings while
    /// the app was away must not leave it believing it can still scan.
    @MainActor
    func testRefreshPicksUpAPermissionRevokedWhileTheAppWasBackgrounded() {
        let provider = FakeProvider(cameraAuthorization: .authorized)
        let model = ScanRequirementsModel(provider: provider)
        XCTAssertEqual(model.state, .ready)

        provider.cameraAuthorization = .denied
        model.refresh()

        XCTAssertEqual(model.state, .cameraDenied)
    }
}
