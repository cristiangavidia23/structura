import XCTest

final class RelocalizationConfirmationTests: XCTestCase {
    func testConfirmsExactlyOnceAtTheRequiredCount() {
        var confirmation = RelocalizationConfirmation()
        var results: [Bool] = []
        for _ in 0..<5 {
            results.append(confirmation.observe(isReliable: true, requiredConsecutiveFrames: 3))
        }
        // Frame 3 confirms; frames 4 and 5 (after the internal reset) must
        // not confirm again without a fresh unreliable-then-reliable run.
        XCTAssertEqual(results, [false, false, true, false, false])
    }

    func testAnyUnreliableFrameResetsTheCount() {
        var confirmation = RelocalizationConfirmation()
        _ = confirmation.observe(isReliable: true, requiredConsecutiveFrames: 3)
        _ = confirmation.observe(isReliable: true, requiredConsecutiveFrames: 3)
        // One unreliable frame right before the threshold must discard the run.
        let interrupted = confirmation.observe(isReliable: false, requiredConsecutiveFrames: 3)
        XCTAssertFalse(interrupted)

        // Must take a fresh 3 reliable frames from here, not just 1 more.
        XCTAssertFalse(confirmation.observe(isReliable: true, requiredConsecutiveFrames: 3))
        XCTAssertFalse(confirmation.observe(isReliable: true, requiredConsecutiveFrames: 3))
        XCTAssertTrue(confirmation.observe(isReliable: true, requiredConsecutiveFrames: 3))
    }

    func testResetClearsAnInProgressRun() {
        var confirmation = RelocalizationConfirmation()
        _ = confirmation.observe(isReliable: true, requiredConsecutiveFrames: 5)
        _ = confirmation.observe(isReliable: true, requiredConsecutiveFrames: 5)
        confirmation.reset()

        for _ in 0..<4 {
            XCTAssertFalse(confirmation.observe(isReliable: true, requiredConsecutiveFrames: 5))
        }
        XCTAssertTrue(confirmation.observe(isReliable: true, requiredConsecutiveFrames: 5))
    }

    func testRequiredCountOfOneConfirmsImmediately() {
        var confirmation = RelocalizationConfirmation()
        XCTAssertTrue(confirmation.observe(isReliable: true, requiredConsecutiveFrames: 1))
    }
}
