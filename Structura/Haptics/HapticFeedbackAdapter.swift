import Foundation

/// Single call site for Pro Scan haptics: plays the richer CoreHaptics
/// pattern when the engine is available and running, otherwise falls back to
/// `Haptics` (UIFeedbackGenerator) so feedback degrades gracefully instead of
/// going silent. The rest of the app keeps calling `Haptics` directly.
final class HapticFeedbackAdapter {
    private let engineManager: HapticEngineManager
    private var lastTickTime: TimeInterval = 0
    private let minTickInterval: TimeInterval = 0.25 // ~4 Hz ceiling

    init(engineManager: HapticEngineManager) {
        self.engineManager = engineManager
    }

    func meshClosed() {
        if engineManager.isRunning, let pattern = HapticPatterns.meshClosed() {
            engineManager.play(pattern)
        } else {
            Haptics.success()
        }
    }

    func trackingLostProgressive() {
        if engineManager.isRunning, let pattern = HapticPatterns.trackingLostProgressive() {
            engineManager.play(pattern)
        } else {
            Haptics.warning()
        }
    }

    func samplingTick() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastTickTime >= minTickInterval else { return }
        lastTickTime = now

        if engineManager.isRunning, let pattern = HapticPatterns.samplingTick() {
            engineManager.play(pattern)
        }
        // No UIFeedbackGenerator fallback for the ambient tick — it's meant
        // to be subtle background texture, not something worth substituting.
    }
}
