import SwiftUI

@main
struct StructuraApp: App {
    @StateObject private var purchases = PurchaseManager.shared

    init() {
        PurchaseManager.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(purchases)
        }
    }
}
