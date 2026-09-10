import Foundation

/// Pure aggregator for the two ARKit delegate-queue metrics Fase 0 of the
/// architecture audit calls for before touching anything else in the
/// pipeline: "sin línea base todo lo demás es opinión."
///
/// - The real rate ARKit delivers frames at (`didUpdate frame:` calls per
///   second). This is deliberately **not** `PerformanceMonitor.fps`, which
///   counts `CADisplayLink` ticks — the screen's own refresh rate, driven by
///   SwiftUI/UIKit rendering. A device can hold 60 fps on screen while
///   ARKit's actual frame delivery has stalled behind a backed-up delegate
///   queue (finding E7): the two numbers measure different things and
///   diverging between them is itself a diagnostic signal.
/// - How long each frame sits between the moment ARKit captured it
///   (`ARFrame.timestamp`) and the moment the delegate callback that
///   received it actually runs (`CACurrentMediaTime()` at the call site) —
///   a direct, per-frame read on the delegate-queue backlog finding C4
///   describes and Fase 1 targeted. Rising latency here, even while FPS
///   looks fine, is what a queue that's falling behind looks like before it
///   gets bad enough to show up as a frozen mesh.
///
/// No ARKit dependency — only a plain `TimeInterval` is threaded in by the
/// caller, matching `frame.timestamp`'s own documented time base
/// ("time interval since system startup", the same basis
/// `CACurrentMediaTime()` uses) — so, like `ProScanConfig`/`ConfidenceGrid`,
/// this compiles into the host-less `StructuraTests` logic-test target and
/// is exercised with synthetic timestamps, not a real device.
struct DelegateFrameMetrics {
    private(set) var frameCount: Int = 0
    private var latencySumSeconds: TimeInterval = 0
    private var maxLatencySeconds: TimeInterval = 0
    private var windowStartTimestamp: TimeInterval?

    /// One summary of everything accumulated since the last `reset()`.
    struct Snapshot: Equatable {
        let arkitFPS: Double
        let meanDelegateLatencyMs: Double
        let maxDelegateLatencyMs: Double
    }

    /// Folds one ARKit-delivered frame into the running window.
    ///
    /// - Parameters:
    ///   - frameTimestamp: `ARFrame.timestamp` — when ARKit captured this
    ///     frame.
    ///   - now: `CACurrentMediaTime()` (or an equivalent same-time-base
    ///     clock) read at the moment the delegate callback observing this
    ///     frame actually executes.
    mutating func record(frameTimestamp: TimeInterval, now: TimeInterval) {
        if windowStartTimestamp == nil {
            windowStartTimestamp = frameTimestamp
        }
        // Clamped at zero: clock-base drift between `ARFrame.timestamp` and
        // `CACurrentMediaTime()` is expected to be negligible in practice,
        // but a negative "latency" from any such drift would be a
        // nonsensical number to report rather than a real observation.
        let latency = max(0, now - frameTimestamp)
        frameCount += 1
        latencySumSeconds += latency
        maxLatencySeconds = max(maxLatencySeconds, latency)
    }

    /// `nil` if no frames were recorded since the last `reset()`, or the
    /// window has zero elapsed time (e.g. `now` from the same instant as
    /// the only recorded frame) — this never divides by zero.
    func snapshot(now: TimeInterval) -> Snapshot? {
        guard frameCount > 0, let windowStartTimestamp, now > windowStartTimestamp else { return nil }
        let elapsed = now - windowStartTimestamp
        return Snapshot(
            arkitFPS: Double(frameCount) / elapsed,
            meanDelegateLatencyMs: (latencySumSeconds / Double(frameCount)) * 1000,
            maxDelegateLatencyMs: maxLatencySeconds * 1000
        )
    }

    mutating func reset() {
        frameCount = 0
        latencySumSeconds = 0
        maxLatencySeconds = 0
        windowStartTimestamp = nil
    }
}
