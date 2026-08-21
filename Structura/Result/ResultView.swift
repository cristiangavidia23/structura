import SwiftUI
import RoomPlan

struct ResultView: View {
    let scan: ScanRecord
    let store: ScanStore

    @AppStorage("unitSystem") private var unitSystemRaw = UnitSystem.metric.rawValue
    @EnvironmentObject private var purchases: PurchaseManager
    @State private var mode: Mode = .dollhouse
    @State private var shareURL: URL?
    @State private var isPresentingShare = false
    @State private var isPresentingPaywall = false
    @State private var isRenaming = false
    @State private var renameText = ""

    private enum Mode: String, CaseIterable {
        case dollhouse = "3D"
        case plan = "Plano"
    }

    private var unitSystem: UnitSystem {
        UnitSystem(rawValue: unitSystemRaw) ?? .metric
    }

    private var plan: FloorPlan? {
        store.capturedStructure(for: scan).map { FloorPlan(structure: $0) }
    }

    /// `scan` is a value-type snapshot from when this view was pushed; reading
    /// the name back from the store keeps it live after a rename instead of
    /// showing stale text until the view is popped and re-pushed.
    private var currentScan: ScanRecord {
        store.scans.first { $0.id == scan.id } ?? scan
    }

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()
            GraphPaperBackground().ignoresSafeArea()

            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let plan, !plan.walls.isEmpty {
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
                                    .accessibilityHidden(true)
                            }
                            .padding(.trailing, 20)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "Área \(unitSystem.formatArea(squareMeters: plan.floorAreaSquareMeters)), "
                                + "altura \(unitSystem.formatLength(meters: plan.wallHeightMeters)), "
                                + "volumen \(unitSystem.formatVolume(cubicMeters: plan.volumeCubicMeters))"
                        )
                        .accessibilityHint("Toca para ver el detalle de medidas")
                    }
                    .background(Theme.cardBackground)
                }
            }
        }
        .navigationTitle(currentScan.name)
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
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    renameText = currentScan.name
                    isRenaming = true
                } label: {
                    Image(systemName: "pencil")
                }
                .accessibilityLabel("Renombrar")
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
        .sheet(isPresented: $isPresentingPaywall) {
            PaywallView(backgroundPlan: plan)
        }
        .alert("Renombrar escaneo", isPresented: $isRenaming) {
            TextField("Nombre", text: $renameText)
            Button("Cancelar", role: .cancel) {}
            Button("Guardar") {
                store.rename(currentScan, to: renameText)
            }
        }
    }

    private func exportMenu(for plan: FloorPlan) -> some View {
        Menu {
            Button {
                exportOrPaywall { share(PDFExporter.export(scan: currentScan, plan: plan, unitSystem: unitSystem)) }
            } label: {
                Label("Plano acotado (PDF)", systemImage: "doc.richtext")
            }
            Button {
                exportOrPaywall { share(store.usdzURL(for: scan)) }
            } label: {
                Label("Modelo 3D (USDZ)", systemImage: "cube")
            }
            Button {
                exportOrPaywall { share(CSVExporter.export(scan: currentScan, plan: plan)) }
            } label: {
                Label("Medidas (CSV)", systemImage: "tablecells")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .accessibilityLabel("Exportar")
    }

    /// Every export format is premium — v1's free tier lets you scan, not export.
    private func exportOrPaywall(_ export: () -> Void) {
        guard purchases.isPremium else {
            isPresentingPaywall = true
            return
        }
        export()
    }

    private func share(_ url: URL?) {
        guard let url else { return }
        shareURL = url
        isPresentingShare = true
    }

    @ViewBuilder
    private var content: some View {
        if let plan, !plan.walls.isEmpty {
            Group {
                switch mode {
                case .dollhouse:
                    DollhouseSceneView(plan: plan)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                case .plan:
                    FloorPlanView(plan: plan, unitSystem: unitSystem)
                        .padding(8)
                        .transition(.opacity.combined(with: .scale(scale: 1.03)))
                }
            }
            .id(mode)
        } else if plan != nil {
            emptyGeometryState
        } else {
            Text("No se pudo cargar la geometría del escaneo.")
                .font(.subheadline)
                .foregroundStyle(Theme.ink.opacity(0.6))
        }
    }

    /// The geometry loaded but has no walls — a scan that ended almost
    /// immediately, or one done from too far to detect any surface. Distinct
    /// from a load failure: here the file is fine, the capture just didn't
    /// pick up a room.
    private var emptyGeometryState: some View {
        VStack(spacing: 10) {
            Image(systemName: "viewfinder")
                .font(.system(size: 30))
                .foregroundStyle(Theme.ink.opacity(0.3))
            Text("No se detectaron paredes en este escaneo")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.ink)
            Text("Puede pasar si el escaneo terminó muy pronto. Intenta escanear de nuevo, moviéndote más despacio y apuntando a las paredes.")
                .font(.caption)
                .foregroundStyle(Theme.ink.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
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
