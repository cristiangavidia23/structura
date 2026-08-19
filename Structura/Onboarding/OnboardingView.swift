import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var page = 0

    private let slides: [Slide] = [
        Slide(
            title: "Mide sin cinta métrica",
            body: "Apunta la cámara y en segundos tienes las medidas de tu ambiente, con el sensor LiDAR de tu iPhone."
        ),
        Slide(
            title: "Plano y modelo 3D",
            body: "Structura convierte el escaneo en un plano 2D acotado y un modelo 3D del ambiente."
        ),
        Slide(
            title: "Exporta y comparte",
            body: "Lleva tus medidas a PDF, USDZ o CSV para usarlas donde las necesites."
        )
    ]

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()
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

                actionButton
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
    }

    private func slideView(_ slide: Slide) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Text(slide.title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text(slide.body)
                .font(.body)
                .foregroundStyle(Theme.ink.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Spacer()
            Spacer()
        }
        .padding(.bottom, 40)
    }

    private var isLastSlide: Bool { page == slides.count - 1 }

    private var actionButton: some View {
        Button {
            if isLastSlide {
                requestCameraAccessAndFinish()
            } else {
                withAnimation { page += 1 }
            }
        } label: {
            Text(isLastSlide ? "Comenzar" : "Siguiente")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 50)
        }
        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
    }

    /// Requesting access here — rather than waiting for the first capture attempt
    /// — is the point of putting this on the last onboarding slide: the ask comes
    /// with context for why the app wants the camera, not as a cold system prompt.
    private func requestCameraAccessAndFinish() {
        AVCaptureDevice.requestAccess(for: .video) { _ in
            DispatchQueue.main.async {
                hasCompletedOnboarding = true
            }
        }
    }

    private struct Slide {
        let title: String
        let body: String
    }
}

#Preview {
    OnboardingView()
}
