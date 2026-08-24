import CoreHaptics

/// The three capture-flow haptic patterns: mesh-closed confirmation,
/// progressive tracking-lost warning, and a subtle continuous sampling tick.
enum HapticPatterns {
    /// Sharp, single strong transient — confirms a closed mesh region or
    /// scan-finish tap.
    static func meshClosed() -> CHHapticPattern? {
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.8)
            ],
            relativeTime: 0
        )
        return try? CHHapticPattern(events: [event], parameters: [])
    }

    /// Escalating intensity/sharpness curve over ~1.5s, meant to be re-fired
    /// when tracking transitions into `.limited`/`.notAvailable`.
    static func trackingLostProgressive() -> CHHapticPattern? {
        let duration: TimeInterval = 1.5
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.3),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3)
            ],
            relativeTime: 0,
            duration: duration
        )
        let intensityCurve = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                CHHapticParameterCurve.ControlPoint(relativeTime: 0, value: 0.2),
                CHHapticParameterCurve.ControlPoint(relativeTime: duration, value: 1.0)
            ],
            relativeTime: 0
        )
        return try? CHHapticPattern(events: [event], parameterCurves: [intensityCurve])
    }

    /// Low-intensity periodic tap for "still scanning, data flowing" ambient
    /// feedback. Callers should rate-limit invocations (~2-4 Hz max).
    static func samplingTick() -> CHHapticPattern? {
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.25),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
            ],
            relativeTime: 0
        )
        return try? CHHapticPattern(events: [event], parameters: [])
    }
}
