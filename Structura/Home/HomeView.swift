import SwiftUI
import RoomPlan

struct HomeView: View {
    @StateObject private var store = ScanStore()
    @EnvironmentObject private var purchases: PurchaseManager
    @State private var isPresentingCapture = false
    @State private var isPresentingPaywall = false
    @State private var isSaving = false
    @State private var saveErrorMessage: String?

    /// v1 pricing: the first scan is free (export is what's gated, not scanning
    /// it); any scan beyond that needs premium.
    private static let freeScanCount = 1

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                Theme.paper.ignoresSafeArea()

                if store.scans.isEmpty && !isSaving {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            if isSaving {
                                SavingCard()
                            }
                            ForEach(store.scans) { scan in
                                NavigationLink {
                                    ResultView(scan: scan, store: store)
                                } label: {
                                    ScanCard(scan: scan, store: store)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        store.delete(scan)
                                    } label: {
                                        Label("Eliminar", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(16)
                        .padding(.bottom, 72)
                    }
                }

                newScanButton
            }
            .navigationTitle("Structura")
            .fullScreenCover(isPresented: $isPresentingCapture) {
                CaptureView { room in
                    isSaving = true
                    Task {
                        let name = "Escaneo \(store.scans.count + 1)"
                        let saved = await store.save(capturedRoom: room, name: name)
                        isSaving = false
                        if saved == nil {
                            saveErrorMessage = "No se pudo guardar el escaneo. Intenta escanear de nuevo."
                        }
                    }
                }
            }
            .alert("Error al guardar", isPresented: errorPresented) {
                Button("Cerrar", role: .cancel) { saveErrorMessage = nil }
            } message: {
                Text(saveErrorMessage ?? "")
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
              let room = store.capturedRoom(for: latest) else { return nil }
        return FloorPlan(room: room)
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { saveErrorMessage != nil },
            set: { isPresented in if !isPresented { saveErrorMessage = nil } }
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
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Theme.accent, in: Circle())
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        }
        .padding(24)
        .accessibilityLabel("Nuevo escaneo")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "viewfinder")
                .font(.system(size: 36))
                .foregroundStyle(Theme.ink.opacity(0.4))
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

/// Placeholder shown while a freshly captured room is being exported to USDZ
/// and thumbnailed — that work can take a couple of seconds, and without this
/// the new card just pops in unexplained.
private struct SavingCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.cardBackground)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.cardBackground)
                if let url = store.thumbnailURL(for: scan),
                   let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.ink.opacity(0.3))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipped()

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
