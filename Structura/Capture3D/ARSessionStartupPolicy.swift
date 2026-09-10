import Foundation

/// Fase 3 of the architecture audit, finding E6: what `ARPointCloudSession`
/// should do when ARKit reports `session(_:didFailWithError:)` shortly
/// after `start()` calls `session.run(...)`.
///
/// The original code waited a fixed `asyncAfter(0.3)` before ever calling
/// `run()`, guessing how long RoomPlan's own `ARSession` would take to
/// finish releasing the camera (ARKit allows only one active session per
/// process). A fixed guess is either too short (the failure this policy
/// exists to retry can still happen on a slower device or after a large
/// RoomPlan capture) or too long (every scan pays the full 300 ms even when
/// the camera was already free the moment this pass started). Reacting to
/// the actual failure ARKit reports — and retrying with backoff — starts
/// as soon as the session is genuinely ready instead of after an arbitrary
/// delay, while still giving up cleanly rather than retrying forever if the
/// failure turns out not to be this specific, transient conflict.
///
/// # A disclosed assumption, not a documented API contract
///
/// This assumes that starting a second `ARSession` while a just-stopped one
/// hasn't finished releasing the camera fails fast via `didFailWithError`,
/// rather than succeeding while silently degraded (e.g. running but never
/// delivering a frame). That is the ordinary AVFoundation/ARKit pattern for
/// a camera-resource conflict, and it is what the original code's own
/// comment implied by calling this a race with RoomPlan's teardown — but
/// Apple does not document this exact failure mode, and there is no
/// compiler or physical device available in this working environment to
/// confirm it empirically. If a real-device test instead shows ARKit
/// succeeding but never delivering frames, this policy's signal (an early
/// `didFailWithError`) would need to change to something like "no frame
/// received within N seconds of `run()`" instead — check this against a
/// real device before trusting it in the field.
///
/// Pure `Foundation`, no ARKit dependency, so — like `AngularVelocityGate`/
/// `ScanDriftBudget` — this compiles into the host-less `StructuraTests`
/// logic-test target and has a direct unit test, not just its ARKit call
/// site.
enum ARSessionStartupPolicy {
    /// One decision returned by `decision(afterFailureAt:attempt:)`.
    enum Decision: Equatable {
        /// Call `run()` again after waiting this many seconds.
        case retry(afterSeconds: TimeInterval)
        /// Stop retrying and surface the failure to the user.
        case giveUp
    }

    /// How many total `run()` attempts (the first attempt plus retries) to
    /// make before giving up. An engineering placeholder: at the backoff
    /// schedule below, 5 total attempts sum to a little over a second of
    /// retrying — generous next to RoomPlan's teardown (typically well
    /// under the 300 ms this policy replaces), without retrying
    /// indefinitely in a way that could mask a real, non-transient failure
    /// as if it were still "almost ready."
    static let maximumAttempts = 5

    /// A `didFailWithError` this soon after `run()` was called almost
    /// certainly means the session never actually started capturing (the
    /// single-active-session conflict this policy exists to retry), rather
    /// than an unrelated failure partway through a session that had
    /// genuinely been running. Deliberately short — this only needs to
    /// separate "failed essentially immediately" from "ran for a while,
    /// then failed for an unrelated reason," which should be surfaced to
    /// the user immediately instead of retried.
    static let earlyFailureWindowSeconds: TimeInterval = 1.0

    /// Capped exponential backoff: 100 ms, 200 ms, 400 ms, 800 ms, 800 ms,
    /// ... — doubles each attempt, capped at 800 ms so a persistent
    /// conflict doesn't retry in a tight loop.
    static func backoffSeconds(forAttempt attempt: Int) -> TimeInterval {
        let uncapped = 0.1 * pow(2.0, Double(max(attempt, 0)))
        return min(uncapped, 0.8)
    }

    /// - Parameters:
    ///   - secondsSinceRun: how long after the `run()` call that just
    ///     failed the failure was reported.
    ///   - attempt: how many attempts have been made so far, including the
    ///     one that just failed (1 for the failure following the very
    ///     first `run()` call, 2 for the one following the first retry,
    ///     and so on).
    static func decision(afterFailureAt secondsSinceRun: TimeInterval, attempt: Int) -> Decision {
        guard secondsSinceRun < earlyFailureWindowSeconds, attempt < maximumAttempts else {
            return .giveUp
        }
        // `attempt` is 1-based (attempts already made); `backoffSeconds`
        // is 0-based (the index into the backoff schedule) — attempt 1's
        // failure uses the schedule's first entry (index 0, 100 ms), not
        // its second (index 1, 200 ms).
        return .retry(afterSeconds: backoffSeconds(forAttempt: attempt - 1))
    }
}
