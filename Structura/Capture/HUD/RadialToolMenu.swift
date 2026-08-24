import SwiftUI

struct RadialToolItem: Identifiable {
    let id = UUID()
    let systemImage: String
    let isActive: Bool
    let action: () -> Void
}

/// Spring-animated radial menu for Pro Scan tools (heatmap toggle, capture
/// toggle, finish). Anchored bottom-trailing, opens outward from a single
/// glass fab button.
struct RadialToolMenu: View {
    let items: [RadialToolItem]
    @State private var isOpen = false

    private let radius: CGFloat = 92
    private let arc: Double = 100

    var body: some View {
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                menuButton(item)
                    .offset(isOpen ? offset(for: index) : .zero)
                    .opacity(isOpen ? 1 : 0)
                    .scaleEffect(isOpen ? 1 : 0.4)
                    .animation(HUDStyle.menuSpring.delay(isOpen ? Double(index) * 0.03 : 0), value: isOpen)
            }

            fab
        }
    }

    private func offset(for index: Int) -> CGSize {
        guard items.count > 1 else { return CGSize(width: -radius, height: 0) }
        let step = arc / Double(items.count - 1)
        let angle = Angle(degrees: -90 - arc / 2 + step * Double(index))
        return CGSize(width: radius * cos(angle.radians), height: radius * sin(angle.radians))
    }

    private var fab: some View {
        Button {
            withAnimation(HUDStyle.menuSpring) { isOpen.toggle() }
        } label: {
            Image(systemName: isOpen ? "xmark" : "wand.and.stars")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(HUDStyle.glass, in: Circle())
                .overlay(Circle().strokeBorder(HUDStyle.panelStroke))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        }
        .accessibilityLabel("Herramientas de escaneo")
    }

    private func menuButton(_ item: RadialToolItem) -> some View {
        Button(action: item.action) {
            Image(systemName: item.systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(item.isActive ? Theme.accent : .white)
                .frame(width: 44, height: 44)
                .background(HUDStyle.glass, in: Circle())
                .overlay(Circle().strokeBorder(HUDStyle.panelStroke))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        }
    }
}
