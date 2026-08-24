import CoreHaptics

/// Owns the CHHapticEngine lifecycle for the capture flow. Started/stopped
/// alongside Pro Scan capture, not app-wide — avoids battery drain and
/// engine-reset churn while idle.
final class HapticEngineManager {
    private var engine: CHHapticEngine?
    private(set) var isRunning = false

    static var supportsHaptics: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    func start() {
        guard Self.supportsHaptics else { return }
        guard engine == nil else {
            restartIfNeeded()
            return
        }

        do {
            let engine = try CHHapticEngine()
            engine.resetHandler = { [weak self] in
                self?.isRunning = false
                self?.restartIfNeeded()
            }
            engine.stoppedHandler = { [weak self] _ in
                // Interruption (call, backgrounding, audio session loss, idle
                // timeout): mark stopped and let the next `play()` restart
                // lazily rather than fighting a real interruption here.
                self?.isRunning = false
            }
            try engine.start()
            self.engine = engine
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    func stop() {
        engine?.stop()
        isRunning = false
    }

    func play(_ pattern: CHHapticPattern) {
        guard Self.supportsHaptics else { return }
        restartIfNeeded()
        guard let engine, isRunning else { return }
        do {
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Best-effort feedback; a dropped haptic never blocks the scan.
        }
    }

    private func restartIfNeeded() {
        guard let engine, !isRunning else { return }
        do {
            try engine.start()
            isRunning = true
        } catch {
            isRunning = false
        }
    }
}
