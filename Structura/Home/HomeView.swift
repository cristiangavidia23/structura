import SwiftUI
import RoomPlan

struct HomeView: View {
    @StateObject private var store = ScanStore()
    @EnvironmentObject private var purchases: PurchaseManager
    @State private var isPresentingCapture = false
    @State private var isPresentingPaywall = false
    @State private var isSaving = false
    @State private var saveErrorMessage: String?
    @State private var renamingScan: ScanRecord?
    @State private var renameText = ""
    @State private var deletingScan: ScanRecord?

    /// v1 pricing: the first scan is free (export is what's gated, not scanning
    /// it); any scan beyond that needs premium.
    private static let freeScanCount = 1

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 18)]

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                Theme.paper.ignoresSafeArea()
                GraphPaperBackground().ignoresSafeArea()

                if store.scans.isEmpty && !isSaving {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 18) {
                            if isSaving {
                                SavingCard()
                            }
                            ForEach(Array(store.scans.enumerated()), id: \.element.id) { index, scan in
                                NavigationLink {
                                    ResultView(scan: scan, store: store)
                                } label: {
                                    ScanCard(scan: scan, store: store, sheetNumber: index + 1)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        renameText = scan.name
                                        renamingScan = scan
                                    } label: {
                                        Label("Renombrar", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        deletingScan = scan
                                    } label: {
                                        Label("Eliminar", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(16)
                        .padding(.bottom, 88)
                    }
                }

                newScanButton
            }
            .navigationTitle("Structura")
            .fullScreenCover(isPresented: $isPresentingCapture) {
                CaptureView { structure in
                    isSaving = true
                    Task {
                        let name = "Escaneo \(store.scans.count + 1)"
                        let saved = await store.save(capturedStructure: structure, name: name)
                        isSaving = false
                        if saved == nil {
                            Haptics.warning()
                            saveErrorMessage = "No se pudo guardar el escaneo. Intenta escanear de nuevo."
                        } else {
                            Haptics.success()
                        }
                    }
                }
            }
            .alert("Error al guardar", isPresented: errorPresented) {
                Button("Cerrar", role: .cancel) { saveErrorMessage = nil }
            } message: {
                Text(saveErrorMessage ?? "")
            }
            .alert("Renombrar escaneo", isPresented: renamingPresented) {
                TextField("Nombre", text: $renameText)
                Button("Cancelar", role: .cancel) { renamingScan = nil }
                Button("Guardar") {
                    if let renamingScan {
                        store.rename(renamingScan, to: renameText)
                    }
                    renamingScan = nil
                }
            }
            .confirmationDialog(
                "¿Eliminar \"\(deletingScan?.name ?? "")\"?",
                isPresented: deletingPresented,
                titleVisibility: .visible
            ) {
                Button("Eliminar", role: .destructive) {
                    if let deletingScan {
                        Haptics.warning()
                        store.delete(deletingScan)
                    }
                    deletingScan = nil
                }
                Button("Cancelar", role: .cancel) { deletingScan = nil }
            } message: {
                Text("Se borrará el modelo 3D, el plano y la nube de puntos de este escaneo. No se puede deshacer.")
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Ajustes")
                }
            }
            .sheet(isPresented: $isPresentingPaywall) {
                PaywallView(backgroundPlan: latestPlan)
            }
        }
    }

    /// Most recent scan's geometry, for the paywall's decorative backdrop.
    private var latestPlan: FloorPlan? {
        guard let latest = store.scans.first,
              let structure = store.capturedStructure(for: latest) else { return nil }
        return FloorPlan(structure: structure)
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { saveErrorMessage != nil },
            set: { isPresented in if !isPresented { saveErrorMessage = nil } }
        )
    }

    private var renamingPresented: Binding<Bool> {
        Binding(
            get: { renamingScan != nil },
            set: { isPresented in if !isPresented { renamingScan = nil } }
        )
    }

    private var deletingPresented: Binding<Bool> {
        Binding(
            get: { deletingScan != nil },
            set: { isPresented in if !isPresented { deletingScan = nil } }
        )
    }

    private var newScanButton: some View {
        Button {
            if store.scans.count >= Self.freeScanCount && !purchases.isPremium {
                isPresentingPaywall = true
            } else {
                isPresentingCapture = true
            }
        } label: {
            ZStack {
                Circle()
                    .stroke(Theme.accent.opacity(0.35), lineWidth: 1)
                    .frame(width: 68, height: 68)
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 56, height: 56)
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        }
        .padding(24)
        .accessibilityLabel("Nuevo escaneo")
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Theme.ink.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                CornerBrackets(color: Theme.ink.opacity(0.35), length: 16, inset: 6)
                Image(systemName: "viewfinder")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.ink.opacity(0.35))
            }
            .frame(width: 120, height: 120)

            VStack(spacing: 6) {
                Text("Todavía no tienes escaneos")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Text("Toca el botón + para escanear tu primer ambiente.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
    }
}

/// Placeholder shown while a freshly captured room is being exported to USDZ
/// and thumbnailed — that work can take a couple of seconds, and without this
/// the new card just pops in unexplained.
private struct SavingCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Theme.cardBackground
                CornerBrackets(color: Theme.ink.opacity(0.25), length: 12)
                ProgressView()
            }
            .aspectRatio(1, contentMode: .fit)

            Text("Guardando…")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.ink.opacity(0.5))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Guardando escaneo")
    }
}

private struct ScanCard: View {
    let scan: ScanRecord
    let store: ScanStore
    let sheetNumber: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                Theme.cardBackground
                if let url = store.thumbnailURL(for: scan),
                   let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.ink.opacity(0.3))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                CornerBrackets(color: Theme.ink.opacity(0.3), length: 12, inset: 4)

                Text(String(format: "%02d", sheetNumber))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.paper)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Theme.ink.opacity(0.65), in: RoundedRectangle(cornerRadius: 3))
                    .padding(7)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Theme.ink.opacity(0.12), lineWidth: 1)
            )

            Text(scan.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)

            Text(scan.createdAt, format: .dateTime.day().month().year())
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.ink.opacity(0.5))
        }
        // Without this, VoiceOver reads the thumbnail, name, and date as three
        // separate stops; grouped, it reads once as a single navigable card.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(scan.name), \(scan.createdAt.formatted(date: .abbreviated, time: .omitted))")
        .accessibilityHint("Toca para ver el plano y las medidas")
    }
}

#Preview {
    HomeView()
}
