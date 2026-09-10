import XCTest

/// Fase 3 of the architecture audit, finding E6 — see
/// `ARSessionStartupPolicy`'s doc comment for the reasoning this pins down.
final class ARSessionStartupPolicyTests: XCTestCase {

    // MARK: - backoffSeconds

    func testBackoffScheduleDoublesEachAttemptUpToTheCap() {
        XCTAssertEqual(ARSessionStartupPolicy.backoffSeconds(forAttempt: 0), 0.1, accuracy: 0.0001)
        XCTAssertEqual(ARSessionStartupPolicy.backoffSeconds(forAttempt: 1), 0.2, accuracy: 0.0001)
        XCTAssertEqual(ARSessionStartupPolicy.backoffSeconds(forAttempt: 2), 0.4, accuracy: 0.0001)
        XCTAssertEqual(ARSessionStartupPolicy.backoffSeconds(forAttempt: 3), 0.8, accuracy: 0.0001)
    }

    func testBackoffScheduleCapsAtEightHundredMilliseconds() {
        XCTAssertEqual(ARSessionStartupPolicy.backoffSeconds(forAttempt: 4), 0.8, accuracy: 0.0001)
        XCTAssertEqual(ARSessionStartupPolicy.backoffSeconds(forAttempt: 10), 0.8, accuracy: 0.0001)
    }

    func testBackoffScheduleClampsNegativeAttemptToTheFirstStep() {
        XCTAssertEqual(ARSessionStartupPolicy.backoffSeconds(forAttempt: -1), 0.1, accuracy: 0.0001)
    }

    // MARK: - decision

    func testDecisionRetriesAnEarlyFirstFailureWithTheFirstBackoffStep() {
        let decision = ARSessionStartupPolicy.decision(afterFailureAt: 0.05, attempt: 1)
        XCTAssertEqual(decision, .retry(afterSeconds: 0.1))
    }

    func testDecisionRetriesASecondEarlyFailureWithTheSecondBackoffStep() {
        let decision = ARSessionStartupPolicy.decision(afterFailureAt: 0.2, attempt: 2)
        XCTAssertEqual(decision, .retry(afterSeconds: 0.2))
    }

    func testDecisionGivesUpOnceMaximumAttemptsIsReached() {
        // `attempt` equal to `maximumAttempts` means every allotted attempt
        // (including this failed one) has already happened.
        let decision = ARSessionStartupPolicy.decision(
            afterFailureAt: 0.05, attempt: ARSessionStartupPolicy.maximumAttempts
        )
        XCTAssertEqual(decision, .giveUp)
    }

    func testDecisionGivesUpOnAFailureOutsideTheEarlyWindowRegardlessOfAttemptCount() {
        // A failure long after `run()` succeeded is treated as a real,
        // unrelated failure — not the transient startup conflict this
        // policy exists to retry — even on the very first attempt.
        let decision = ARSessionStartupPolicy.decision(afterFailureAt: 5.0, attempt: 1)
        XCTAssertEqual(decision, .giveUp)
    }

    func testDecisionTreatsTheEarlyWindowBoundaryAsNotEarly() {
        let decision = ARSessionStartupPolicy.decision(
            afterFailureAt: ARSessionStartupPolicy.earlyFailureWindowSeconds, attempt: 1
        )
        XCTAssertEqual(decision, .giveUp)
    }

    func testDecisionRetriesJustUnderTheEarlyWindowBoundary() {
        let decision = ARSessionStartupPolicy.decision(
            afterFailureAt: ARSessionStartupPolicy.earlyFailureWindowSeconds - 0.01, attempt: 1
        )
        if case .retry = decision {
            // Expected.
        } else {
            XCTFail("Expected a retry just under the early-failure window boundary, got \(decision).")
        }
    }
}
