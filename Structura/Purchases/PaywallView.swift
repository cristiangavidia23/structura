import SwiftUI
import RevenueCat

struct PaywallView: View {
    /// The most recent scan's geometry, shown faintly behind the pitch — real
    /// data instead of a stock illustration.
    var backgroundPlan: FloorPlan?

    @EnvironmentObject private var purchases: PurchaseManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPackage: Package?
    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()

            if let backgroundPlan {
                BlueprintBackdrop(plan: backgroundPlan)
                    .opacity(0.08)
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                closeButton

                ScrollView {
                    VStack(spacing: 28) {
                        pitch

                        if let offering = purchases.offering {
                            packages(offering)
                        } else if let offeringsError = purchases.offeringsError {
                            offeringsErrorView(offeringsError)
                        } else {
                            ProgressView()
                                .padding(.top, 40)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                }

                footer
            }
        }
        .task {
            if purchases.offering == nil {
                await purchases.loadOfferings()
            }
            selectDefaultPackage()
        }
        .alert("No se pudo completar la compra", isPresented: errorPresented) {
            Button("Cerrar", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: purchases.isPremium) {
            if purchases.isPremium { dismiss() }
        }
    }

    private func selectDefaultPackage() {
        guard selectedPackage == nil else { return }
        selectedPackage = purchases.offering?.availablePackages.first {
            $0.storeProduct.subscriptionPeriod?.unit == .year
        } ?? purchases.offering?.availablePackages.first
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var closeButton: some View {
        HStack {
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.ink.opacity(0.5))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Cerrar")
        }
        .padding(.trailing, 8)
    }

    private var pitch: some View {
        VStack(spacing: 10) {
            Text("Structura Premium")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.ink)

            Text("Exporta tus planos y escanea sin límite")
                .font(.subheadline)
                .foregroundStyle(Theme.ink.opacity(0.6))
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 10) {
                benefit("square.and.arrow.up", "Exporta PDF, USDZ y CSV")
                benefit("viewfinder", "Escaneos ilimitados")
                benefit("ruler", "Medidas y plano acotado sin marca de agua")
            }
            .padding(.top, 8)
        }
    }

    private func benefit(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
        }
    }

    private func packages(_ offering: Offering) -> some View {
        VStack(spacing: 12) {
            ForEach(offering.availablePackages, id: \.identifier) { package in
                PackageCard(
                    package: package,
                    isSelected: selectedPackage?.identifier == package.identifier
                )
                .onTapGesture { selectedPackage = package }
            }
        }
    }

    private func offeringsErrorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Text("No se pudieron cargar los planes")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.ink.opacity(0.6))
                .multilineTextAlignment(.center)
            Button("Reintentar") {
                Task { await purchases.loadOfferings() }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.accent)
            .padding(.top, 4)
        }
        .padding(.top, 40)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Button {
                purchase()
            } label: {
                ZStack {
                    if isPurchasing {
                        ProgressView().tint(.white)
                    } else {
                        Text(ctaTitle)
                            .font(.body.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 50)
            }
            .foregroundStyle(.white)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
            .disabled(selectedPackage == nil || isPurchasing)

            Button {
                restore()
            } label: {
                if isRestoring {
                    ProgressView()
                } else {
                    Text("Restaurar compras")
                        .font(.footnote)
                        .foregroundStyle(Theme.ink.opacity(0.55))
                }
            }
            .disabled(isRestoring)

            Text(
                "El pago se cobra a tu cuenta de Apple al confirmar. La suscripción se "
                    + "renueva automáticamente a menos que se cancele al menos 24 horas "
                    + "antes de que termine el período actual, en Ajustes > tu perfil > "
                    + "Suscripciones."
            )
            .font(.caption2)
            .foregroundStyle(Theme.ink.opacity(0.4))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 20)
    }

    private var ctaTitle: String {
        guard let package = selectedPackage else { return "Continuar" }
        if package.storeProduct.introductoryDiscount?.paymentMode == .freeTrial {
            return "Empezar prueba gratis"
        }
        return "Continuar"
    }

    private func purchase() {
        guard let package = selectedPackage else { return }
        isPurchasing = true
        Task {
            defer { isPurchasing = false }
            do {
                try await purchases.purchase(package)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func restore() {
        isRestoring = true
        Task {
            defer { isRestoring = false }
            do {
                try await purchases.restore()
                if !purchases.isPremium {
                    errorMessage = "No encontramos una compra activa para restaurar."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct PackageCard: View {
    let package: Package
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                if let trialText {
                    Text(trialText)
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
            }
            Spacer()
            Text(package.storeProduct.localizedPriceString)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
        }
        .padding(16)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isSelected ? Theme.accent : Theme.ink.opacity(0.12), lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var title: String {
        switch package.storeProduct.subscriptionPeriod?.unit {
        case .year: return "Anual"
        case .month: return "Mensual"
        case .week: return "Semanal"
        case .day: return "Diario"
        case .none: return package.storeProduct.localizedTitle
        @unknown default: return package.storeProduct.localizedTitle
        }
    }

    private var trialText: String? {
        guard let discount = package.storeProduct.introductoryDiscount,
              discount.paymentMode == .freeTrial else { return nil }
        let value = discount.subscriptionPeriod.value
        switch discount.subscriptionPeriod.unit {
        case .day: return "\(value) día\(value == 1 ? "" : "s") gratis"
        case .week: return "\(value) semana\(value == 1 ? "" : "s") gratis"
        case .month: return "\(value) mes\(value == 1 ? "" : "es") gratis"
        case .year: return "\(value) año\(value == 1 ? "" : "s") gratis"
        @unknown default: return nil
        }
    }
}
