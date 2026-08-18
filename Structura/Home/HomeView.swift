import SwiftUI
import RoomPlan

struct HomeView: View {
    @StateObject private var store = ScanStore()
    @State private var isPresentingCapture = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                Theme.paper.ignoresSafeArea()

                if store.scans.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
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
                    Task {
                        let name = "Escaneo \(store.scans.count + 1)"
                        await store.save(capturedRoom: room, name: name)
                    }
                }
            }
        }
    }

    private var newScanButton: some View {
        Button {
            isPresentingCapture = true
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
    }
}

#Preview {
    HomeView()
}
