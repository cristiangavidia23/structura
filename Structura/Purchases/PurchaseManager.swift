import Foundation
import RevenueCat

/// Wraps RevenueCat behind the one thing the rest of the app actually needs:
/// "is this device entitled to premium." Everything else (offerings, purchase
/// flow, restore) exists to answer or change that.
@MainActor
final class PurchaseManager: NSObject, ObservableObject {
    static let shared = PurchaseManager()

    /// From RevenueCat → Project → API Keys → iOS (public SDK key, starts "appl_").
    /// Until this is set, the SDK is never configured and the app safely treats
    /// everyone as non-premium — the paywall still shows, purchases just can't
    /// complete yet.
    private static let apiKey = "appl_SsGwZthaCzBiCTYnJOojunUGPOT"

    /// Must match the Entitlement identifier created in the RevenueCat dashboard.
    private static let entitlementID = "premium"

    @Published private(set) var isPremium = false
    @Published private(set) var offering: Offering?

    private var isConfigured: Bool { Self.apiKey != "REVENUECAT_API_KEY" }

    func configure() {
        guard isConfigured else {
            print("⚠️ PurchaseManager: RevenueCat API key not set — running with premium locked off.")
            return
        }
        Purchases.logLevel = .warn
        Purchases.configure(withAPIKey: Self.apiKey)
        Purchases.shared.delegate = self
        Task { await refreshCustomerInfo() }
        Task { await loadOfferings() }
    }

    func refreshCustomerInfo() async {
        guard isConfigured, let info = try? await Purchases.shared.customerInfo() else { return }
        apply(info)
    }

    func loadOfferings() async {
        guard isConfigured, let offerings = try? await Purchases.shared.offerings() else { return }
        offering = offerings.current
    }

    /// Throws on failure; a user-initiated cancel is reported via `userCancelled`,
    /// not a thrown error, so the caller can distinguish "declined" from "broke."
    @discardableResult
    func purchase(_ package: Package) async throws -> Bool {
        let result = try await Purchases.shared.purchase(package: package)
        apply(result.customerInfo)
        return !result.userCancelled
    }

    func restore() async throws {
        let info = try await Purchases.shared.restorePurchases()
        apply(info)
    }

    private func apply(_ info: CustomerInfo) {
        isPremium = info.entitlements[Self.entitlementID]?.isActive == true
    }
}

extension PurchaseManager: PurchasesDelegate {
    nonisolated func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
        Task { @MainActor in
            self.apply(customerInfo)
        }
    }
}
