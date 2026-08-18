import SwiftUI
import RoomPlan

struct ResultView: View {
    let scan: ScanRecord
    let store: ScanStore

    @AppStorage("unitSystem") private var unitSystemRaw = UnitSystem.metric.rawValue
    @State private var mode: Mode = .dollhouse
    @State private var shareURL: URL?
    @State private var isPresentingShare = false

    private enum Mode: String, CaseIterable {
        case dollhouse = "3D"
        case plan = "Plano"
    }

    private var unitSystem: UnitSystem {
        UnitSystem(rawValue: unitSystemRaw) ?? .metric
    }

    private var plan: FloorPlan? {
        store.capturedRoom(for: scan).map { FloorPlan(room: $0) }
    }

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let plan {
                    VStack(spacing: 0) {
                        if mode == .plan, let caveat = caveat(for: plan) {
                            Text(caveat)
                                .font(.caption)
                                .foregroundStyle(Theme.ink.opacity(0.6))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 20)
                                .padding(.top, 12)
                                .transition(.opacity)
                        }

                        NavigationLink {
                            MeasurementsView(plan: plan, unitSystem: unitSystem)
                        } label: {
                            HStack(spacing: 8) {
                                summary(for: plan)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Theme.ink.opacity(0.35))
                            }
                            .padding(.trailing, 20)
                        }
                        .buttonStyle(.plain)
                    }
                    .background(Theme.cardBackground)
                }
            }
        }
        .navigationTitle(scan.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Vista", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }
            if let plan {
                ToolbarItem(placement: .topBarTrailing) {
                    exportMenu(for: plan)
                }
            }
        }
        .animation(.smooth(duration: 0.85), value: mode)
        .sheet(isPresented: $isPresentingShare) {
            if let shareURL {
                ActivityView(items: [shareURL])
            }
        }
    }

    private func exportMenu(for plan: FloorPlan) -> some View {
        Menu {
            Button {
                share(PDFExporter.export(scan: scan, plan: plan, unitSystem: unitSystem))
            } label: {
                Label("Plano acotado (PDF)", systemImage: "doc.richtext")
            }
            Button {
                share(store.usdzURL(for: scan))
            } label: {
                Label("Modelo 3D (USDZ)", systemImage: "cube")
            }
            Button {
                share(CSVExporter.export(scan: scan, plan: plan))
            } label: {
                Label("Medidas (CSV)", systemImage: "tablecells")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
    }

    private func share(_ url: URL?) {
        guard let url else { return }
        shareURL = url
        isPresentingShare = true
    }

    @ViewBuilder
    private var content: some View {
        if let plan {
            RoomMorphView(
                plan: plan,
                unitSystem: unitSystem,
                progress: mode == .plan ? 1 : 0
            )
            .padding(8)
        } else {
            Text("No se pudo cargar la geometría del escaneo.")
                .font(.subheadline)
                .foregroundStyle(Theme.ink.opacity(0.6))
        }
    }

    /// Surfaces what the drawing itself cannot: which numbers are inferred, and
    /// where the room is genuinely out of square rather than just noisy.
    private func caveat(for plan: FloorPlan) -> String? {
        var notes: [String] = []

        let approximate = plan.unreliableWalls.count
        if approximate > 0 {
            notes.append(approximate == 1
                ? "1 pared no se escaneó completa (medida aproximada)"
                : "\(approximate) paredes no se escanearon completas (medidas aproximadas)")
        }

        let outOfSquare = plan.outOfSquareWalls.count
        if outOfSquare > 0 {
            notes.append(outOfSquare == 1
                ? "1 pared está fuera de escuadra"
                : "\(outOfSquare) paredes están fuera de escuadra")
        }

        return notes.isEmpty ? nil : notes.joined(separator: " · ")
    }

    private func summary(for plan: FloorPlan) -> some View {
        HStack(spacing: 24) {
            metric(title: "Área", value: unitSystem.formatArea(squareMeters: plan.floorAreaSquareMeters))
            metric(title: "Altura", value: unitSystem.formatLength(meters: plan.wallHeightMeters))
            metric(title: "Volumen", value: unitSystem.formatVolume(cubicMeters: plan.volumeCubicMeters))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func metric(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.ink.opacity(0.55))
            Text(value)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
        }
    }
}
