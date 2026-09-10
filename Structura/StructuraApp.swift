import SwiftUI

@main
struct StructuraApp: App {
    @StateObject private var purchases = PurchaseManager.shared
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var requirements = ScanRequirementsModel(provider: SystemScanRequirementsProbe())
    @Environment(\.scenePhase) private var scenePhase

    init() {
        PurchaseManager.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .environmentObject(purchases)
                .onChange(of: scenePhase) { _, phase in
                    // The user can grant or revoke the camera in Settings
                    // while Structura is backgrounded, and iOS does not tell
                    // the app when they do — so the requirements are re-read
                    // on every return to the foreground rather than only at
                    // launch.
                    if phase == .active { requirements.refresh() }
                }
        }
    }

    /// Hardware first, then onboarding, then permissions, then the app.
    ///
    /// The order is the point:
    ///
    /// - An unsupported device is checked before anything else, because no
    ///   amount of onboarding or permission-granting makes Structura work
    ///   without LiDAR — walking someone through three slides and a camera
    ///   prompt only to dead-end them would be worse than saying so up front.
    /// - Onboarding runs before the permission screens because it is where
    ///   the camera is explained and first requested; reaching a bare
    ///   "permission denied" screen without ever having been told why the app
    ///   wants the camera is exactly the flow App Store review flags.
    /// - The blocked screens come last, and only for users who already saw
    ///   onboarding and refused — the one case where the system prompt will
    ///   not appear again and Settings is the only way back.
    @ViewBuilder
    private var rootView: some View {
        if requirements.state == .unsupportedDevice {
            RequirementsBlockedView(state: .unsupportedDevice) {
                requirements.refresh()
            }
        } else if !hasCompletedOnboarding {
            OnboardingView(requirements: requirements)
        } else if requirements.state.canScan {
            HomeView()
        } else {
            RequirementsBlockedView(state: requirements.state) {
                requirements.refresh()
            }
        }
    }
}
