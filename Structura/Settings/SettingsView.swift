import SwiftUI

struct SettingsView: View {
    @AppStorage("unitSystem") private var unitSystemRaw = UnitSystem.metric.rawValue

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

            Section("Soporte") {
                if let supportMailURL {
                    Link(destination: supportMailURL) {
                        Label("Contactar soporte", systemImage: "envelope")
                            .foregroundStyle(Theme.ink)
                    }
                    .listRowBackground(Theme.cardBackground)
                }
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
    }
}
