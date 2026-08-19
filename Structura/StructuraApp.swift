import SwiftUI

@main
struct StructuraApp: App {
    @StateObject private var purchases = PurchaseManager.shared
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    init() {
        PurchaseManager.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    HomeView()
                } else {
                    OnboardingView()
                }
            }
            .environmentObject(purchases)
        }
    }
}
