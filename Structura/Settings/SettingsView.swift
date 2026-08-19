import SwiftUI

struct SettingsView: View {
    @AppStorage("unitSystem") private var unitSystemRaw = UnitSystem.metric.rawValue
    @EnvironmentObject private var purchases: PurchaseManager
    @State private var isRestoring = false
    @State private var restoreMessage: String?

    private var unitSystem: Binding<UnitSystem> {
        Binding(
            get: { UnitSystem(rawValue: unitSystemRaw) ?? .metric },
            set: { unitSystemRaw = $0.rawValue }
        )
    }

    var body: some View {
        List {
            Section("Medidas") {
                Picker("Unidades", selection: unitSystem) {
                    ForEach(UnitSystem.allCases) { system in
                        Text(system.label).tag(system)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Theme.cardBackground)
                .padding(.vertical, 4)
            }

            Section("Suscripción") {
                HStack {
                    Text("Estado")
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Text(purchases.isPremium ? "Premium" : "Gratis")
                        .foregroundStyle(purchases.isPremium ? Theme.accent : Theme.ink.opacity(0.5))
                }
                .listRowBackground(Theme.cardBackground)

                Button {
                    restore()
                } label: {
                    if isRestoring {
                        ProgressView()
                    } else {
                        Text("Restaurar compras")
                            .foregroundStyle(Theme.ink)
                    }
                }
                .disabled(isRestoring)
                .listRowBackground(Theme.cardBackground)
            }

            Section("Soporte") {
                if let supportMailURL {
                    Link(destination: supportMailURL) {
                        Label("Contactar soporte", systemImage: "envelope")
                            .foregroundStyle(Theme.ink)
                    }
                    .listRowBackground(Theme.cardBackground)
                }
            }

            Section("Legal") {
                Link(destination: LegalLinks.termsOfUse) {
                    Label("Términos de Uso", systemImage: "doc.text")
                        .foregroundStyle(Theme.ink)
                }
                .listRowBackground(Theme.cardBackground)

                Link(destination: LegalLinks.privacyPolicy) {
                    Label("Política de Privacidad", systemImage: "hand.raised")
                        .foregroundStyle(Theme.ink)
                }
                .listRowBackground(Theme.cardBackground)
            }

            Section {
                HStack {
                    Text("Versión")
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Text(appVersion)
                        .foregroundStyle(Theme.ink.opacity(0.5))
                }
                .listRowBackground(Theme.cardBackground)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.paper)
        .navigationTitle("Ajustes")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Restaurar compras", isPresented: restoreMessagePresented) {
            Button("Cerrar", role: .cancel) { restoreMessage = nil }
        } message: {
            Text(restoreMessage ?? "")
        }
    }

    private var restoreMessagePresented: Binding<Bool> {
        Binding(get: { restoreMessage != nil }, set: { if !$0 { restoreMessage = nil } })
    }

    private func restore() {
        isRestoring = true
        Task {
            defer { isRestoring = false }
            do {
                try await purchases.restore()
                restoreMessage = purchases.isPremium
                    ? "Tu suscripción Premium fue restaurada."
                    : "No encontramos una compra activa para restaurar."
            } catch {
                restoreMessage = error.localizedDescription
            }
        }
    }

    private var supportMailURL: URL? {
        let subject = "Structura — Soporte"
        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "mailto:cristian.gavidia23@gmail.com?subject=\(encodedSubject)")
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(PurchaseManager.shared)
    }
}
