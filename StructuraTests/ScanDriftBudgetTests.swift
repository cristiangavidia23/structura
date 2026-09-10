import simd
import XCTest

/// Synthetic-transform tests for `ScanDriftBudget` — Fase 3 of the
/// architecture audit, finding E4.
final class ScanDriftBudgetTests: XCTestCase {

    private func makeTransform(translation: SIMD3<Float> = .zero, rotationAroundYRadians: Float = 0) -> simd_float4x4 {
        let c = cos(rotationAroundYRadians)
        let s = sin(rotationAroundYRadians)
        var transform = simd_float4x4(
            SIMD4<Float>(c, 0, -s, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(s, 0, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        transform.columns.3 = SIMD4<Float>(translation.x, translation.y, translation.z, 1)
        return transform
    }

    func testFirstRecordEstablishesBaselineWithoutAccumulating() {
        var budget = ScanDriftBudget()
        budget.record(transform: makeTransform(translation: SIMD3<Float>(3, 0, 0)))
        XCTAssertEqual(budget.traveledDistanceMeters, 0)
        XCTAssertEqual(budget.accumulatedRotationRadians, 0)
        XCTAssertFalse(budget.isExhausted)
    }

    func testAccumulatesTranslationDistanceBetweenFrames() {
        var budget = ScanDriftBudget()
        budget.record(transform: makeTransform(translation: SIMD3<Float>(0, 0, 0)))
        budget.record(transform: makeTransform(translation: SIMD3<Float>(3, 0, 4)))
        // 3-4-5 triangle: distance is exactly 5.
        XCTAssertEqual(budget.traveledDistanceMeters, 5, accuracy: 0.001)
        XCTAssertEqual(budget.accumulatedRotationRadians, 0, accuracy: 0.001)
    }

    func testAccumulatesTranslationAcrossMultipleFrames() {
        var budget = ScanDriftBudget()
        budget.record(transform: makeTransform(translation: SIMD3<Float>(0, 0, 0)))
        budget.record(transform: makeTransform(translation: SIMD3<Float>(1, 0, 0)))
        budget.record(transform: makeTransform(translation: SIMD3<Float>(1, 0, 1)))
        budget.record(transform: makeTransform(translation: SIMD3<Float>(1, 1, 1)))
        // 1 + 1 + 1 = 3 meters total, not the direct start-to-end distance.
        XCTAssertEqual(budget.traveledDistanceMeters, 3, accuracy: 0.001)
    }

    func testAccumulatesRotationBetweenFrames() {
        var budget = ScanDriftBudget()
        budget.record(transform: makeTransform(rotationAroundYRadians: 0))
        budget.record(transform: makeTransform(rotationAroundYRadians: 1.2))
        XCTAssertEqual(budget.accumulatedRotationRadians, 1.2, accuracy: 0.001)
        XCTAssertEqual(budget.traveledDistanceMeters, 0, accuracy: 0.001)
    }

    func testTranslationBudgetExhaustsPastItsThreshold() {
        var budget = ScanDriftBudget()
        budget.record(transform: makeTransform(translation: .zero))
        budget.record(transform: makeTransform(translation: SIMD3<Float>(5, 0, 0)))
        XCTAssertFalse(budget.isExhausted)

        budget.record(transform: makeTransform(translation: SIMD3<Float>(30, 0, 0)))
        XCTAssertTrue(budget.isExhausted)
        XCTAssertGreaterThanOrEqual(budget.consumedFraction, 1.0)
    }

    func testRotationBudgetExhaustsAfterEnoughAccumulatedTurning() {
        var budget = ScanDriftBudget()
        var angle: Float = 0
        budget.record(transform: makeTransform(rotationAroundYRadians: angle))

        // 1 radian per step, well under the acos-domain-safe range per
        // step, accumulated over enough steps to exceed ~4 full turns
        // (ScanDriftBudget.maximumAccumulatedRotationRadians ≈ 25.13 rad).
        for _ in 0..<20 {
            angle += 1.0
            budget.record(transform: makeTransform(rotationAroundYRadians: angle))
        }
        XCTAssertEqual(budget.accumulatedRotationRadians, 20, accuracy: 0.01)
        XCTAssertFalse(budget.isExhausted, "20 rad should still be under the ~25.13 rad budget.")

        for _ in 0..<10 {
            angle += 1.0
            budget.record(transform: makeTransform(rotationAroundYRadians: angle))
        }
        XCTAssertEqual(budget.accumulatedRotationRadians, 30, accuracy: 0.01)
        XCTAssertTrue(budget.isExhausted, "30 rad should exceed the ~25.13 rad budget.")
    }

    func testConsumedFractionIsTheMaximumOfBothDimensions() {
        var budget = ScanDriftBudget()
        // Half the translation budget, negligible rotation.
        budget.record(transform: makeTransform(translation: .zero))
        budget.record(transform: makeTransform(translation: SIMD3<Float>(7.5, 0, 0)))
        let fraction = budget.consumedFraction
        XCTAssertEqual(fraction, 7.5 / ScanDriftBudget.maximumTraveledDistanceMeters, accuracy: 0.01)
    }

    func testResetClearsCountersAndBaseline() {
        var budget = ScanDriftBudget()
        budget.record(transform: makeTransform(translation: .zero))
        budget.record(transform: makeTransform(translation: SIMD3<Float>(10, 0, 0)))
        XCTAssertGreaterThan(budget.traveledDistanceMeters, 0)

        budget.reset()
        XCTAssertEqual(budget.traveledDistanceMeters, 0)
        XCTAssertEqual(budget.accumulatedRotationRadians, 0)
        XCTAssertFalse(budget.isExhausted)

        // Baseline was also cleared: the very next record only re-establishes
        // it, exactly like a fresh `ScanDriftBudget()`.
        budget.record(transform: makeTransform(translation: SIMD3<Float>(100, 0, 0)))
        XCTAssertEqual(budget.traveledDistanceMeters, 0)
    }

    func testDiscardPreviousTransformKeepsCountersButDropsBaseline() {
        var budget = ScanDriftBudget()
        budget.record(transform: makeTransform(translation: .zero))
        budget.record(transform: makeTransform(translation: SIMD3<Float>(5, 0, 0)))
        XCTAssertEqual(budget.traveledDistanceMeters, 5, accuracy: 0.001)

        // Simulates a session interruption: the coordinate frame may have
        // jumped arbitrarily, so the next frame must not be compared
        // against the pre-interruption transform.
        budget.discardPreviousTransform()
        XCTAssertEqual(budget.traveledDistanceMeters, 5, accuracy: 0.001, "Counters must survive the discard.")

        // A huge apparent jump right after the discard must not be counted
        // — it only re-establishes the baseline.
        budget.record(transform: makeTransform(translation: SIMD3<Float>(500, 500, 500)))
        XCTAssertEqual(budget.traveledDistanceMeters, 5, accuracy: 0.001)

        // Normal accumulation resumes from the new baseline.
        budget.record(transform: makeTransform(translation: SIMD3<Float>(501, 500, 500)))
        XCTAssertEqual(budget.traveledDistanceMeters, 6, accuracy: 0.001)
    }
}
