import SwiftUI

/// Three slides describing what Structura actually does, followed by an
/// explained camera request.
///
/// The copy is deliberately technical rather than consumer-friendly: this app
/// produces LAS 1.4 point clouds and dimensioned plans for construction work,
/// and someone evaluating it needs to know that on the first screen. The last
/// slide states the project's own honesty rule — measured versus inferred —
/// because that is the claim the whole export pipeline is built around.
struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var page = 0

    /// Owned by the app and passed in, so finishing onboarding hands the user
    /// to a screen that already knows the permission result.
    let requirements: ScanRequirementsModel

    private let slides: [Slide] = [
        Slide(
            symbol: "square.split.bottomrightquarter",
            title: "Captura arquitectónica 2D/3D",
            body: "El primer pase usa RoomPlan para reconocer muros, puertas y ventanas, y generar un plano acotado y un modelo 3D navegable del ambiente.",
            detail: "Pase 1 · RoomPlan"
        ),
        Slide(
            symbol: "aqi.medium",
            title: "Nube de puntos de grado topográfico",
            body: "El segundo pase captura con LiDAR una nube densa de puntos con color real y confianza por punto, exportable a PLY y LAS 1.4 para tu software de topografía o CAD.",
            detail: "Pase 2 · Pro Scan"
        ),
        Slide(
            symbol: "checkmark.seal",
            title: "Precisión e integridad",
            body: "Structura distingue siempre lo que midió de lo que infirió: las medidas estimadas se marcan como tales y los puntos sin lectura real de confianza se exportan con un valor centinela, nunca con un número inventado.",
            detail: "Todo el procesamiento y la exportación ocurren en tu dispositivo, sin enviar tus escaneos a la nube."
        )
    ]

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()
            GraphPaperBackground().ignoresSafeArea()
            SketchBackdrop()
                .opacity(0.07)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                        slideView(slide)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                // Shown only on the last slide, where the button actually
                // triggers the permission prompt — an explanation of why the
                // camera is needed, presented *before* the system asks, so
                // the system prompt arrives with context instead of cold.
                if isLastSlide {
                    cameraRationale
                        .padding(.horizontal, 28)
                        .padding(.bottom, 14)
                        .transition(.opacity)
                }

                actionButton
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .animation(.smooth(duration: 0.25), value: page)
    }

    private func slideView(_ slide: Slide) -> some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: slide.symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.accent)
                .padding(.bottom, 6)

            Text(slide.detail)
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.ink.opacity(0.45))
                .textCase(.uppercase)
                .multilineTextAlignment(.center)

            Text(slide.title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)

            Text(slide.body)
                .font(.subheadline)
                .foregroundStyle(Theme.ink.opacity(0.68))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)

            Spacer()
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 40)
        // Frames the slide the way the rest of the app frames measured
        // content, rather than as a plain marketing card.
        .overlay(
            CornerBrackets(color: Theme.ink.opacity(0.25), inset: 12)
                .padding(.horizontal, 12)
                .padding(.vertical, 40)
        )
    }

    private var cameraRationale: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "camera.viewfinder")
                .font(.footnote)
                .foregroundStyle(Theme.accent)
                .padding(.top, 1)
            Text("A continuación te pediremos acceso a la cámara: es lo que Structura usa, junto al sensor LiDAR, para medir. Sin ese permiso no puede escanear.")
                .font(.caption)
                .foregroundStyle(Theme.ink.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Theme.cardBackground.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var isLastSlide: Bool { page == slides.count - 1 }

    private var actionButton: some View {
        Button {
            if isLastSlide {
                Task { await finish() }
            } else {
                withAnimation { page += 1 }
            }
        } label: {
            Text(isLastSlide ? "Comenzar" : "Siguiente")
        }
        .buttonStyle(.primary)
        .disabled(requirements.isRequestingCameraAccess)
    }

    /// Asks for the camera, then marks onboarding complete regardless of the
    /// answer.
    ///
    /// A refusal must not trap the user on the last slide: the app moves on
    /// and `StructuraApp` shows the recoverable "denied" screen, which can
    /// send them to Settings. Re-running onboarding would not help, since iOS
    /// never shows the system prompt twice.
    private func finish() async {
        await requirements.requestCameraAccess()
        hasCompletedOnboarding = true
    }

    private struct Slide {
        let symbol: String
        let title: String
        let body: String
        /// Short label above the title naming the pass or the theme.
        let detail: String
    }
}

#Preview {
    OnboardingView(requirements: ScanRequirementsModel(provider: SystemScanRequirementsProbe()))
}
