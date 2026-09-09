import XCTest

/// Synthetic-timestamp acceptance tests for `DelegateFrameMetrics` — the
/// Fase 0 verification plan calls for proving the FPS/latency math is
/// correct before trusting any number it reports from a real device.
final class DelegateFrameMetricsTests: XCTestCase {

    func testSnapshotIsNilBeforeAnyFrameIsRecorded() {
        var metrics = DelegateFrameMetrics()
        XCTAssertNil(metrics.snapshot(now: 100))
        // Reading the snapshot must not itself perturb the aggregator.
        metrics.record(frameTimestamp: 100, now: 100.1)
        XCTAssertNotNil(metrics.snapshot(now: 100.2))
    }

    func testSnapshotIsNilWhenTheWindowHasNoElapsedTime() {
        var metrics = DelegateFrameMetrics()
        metrics.record(frameTimestamp: 10, now: 10)
        // `now` for the snapshot equals the window's own start — no elapsed
        // time to divide a rate by.
        XCTAssertNil(metrics.snapshot(now: 10))
    }

    func testArkitFPSMatchesFrameCountOverElapsedWindow() throws {
        var metrics = DelegateFrameMetrics()
        // 30 frames delivered evenly across a 1 s window starting at t=0.
        for i in 0..<30 {
            let t = Double(i) / 30.0
            metrics.record(frameTimestamp: t, now: t)
        }
        let snapshot = try XCTUnwrap(metrics.snapshot(now: 1.0))
        XCTAssertEqual(snapshot.arkitFPS, 30.0, accuracy: 0.01)
    }

    func testMeanDelegateLatencyAveragesPerFrameLatency() throws {
        var metrics = DelegateFrameMetrics()
        // Each frame observed 10 ms and 30 ms late, respectively.
        metrics.record(frameTimestamp: 0.000, now: 0.010)
        metrics.record(frameTimestamp: 0.100, now: 0.130)
        let snapshot = try XCTUnwrap(metrics.snapshot(now: 0.200))
        XCTAssertEqual(snapshot.meanDelegateLatencyMs, 20.0, accuracy: 0.01)
    }

    func testMaxDelegateLatencyTracksTheWorstSingleFrameNotTheAverage() throws {
        var metrics = DelegateFrameMetrics()
        metrics.record(frameTimestamp: 0.000, now: 0.005) // 5 ms
        metrics.record(frameTimestamp: 0.100, now: 0.180) // 80 ms — one bad frame
        metrics.record(frameTimestamp: 0.200, now: 0.207) // 7 ms
        let snapshot = try XCTUnwrap(metrics.snapshot(now: 0.300))
        XCTAssertEqual(snapshot.maxDelegateLatencyMs, 80.0, accuracy: 0.01)
        XCTAssertLessThan(snapshot.meanDelegateLatencyMs, snapshot.maxDelegateLatencyMs)
    }

    func testNegativeClockDriftIsClampedRatherThanReportedAsNegativeLatency() throws {
        var metrics = DelegateFrameMetrics()
        // `now` slightly before `frameTimestamp` shouldn't happen in
        // practice, but must never produce a nonsensical negative latency.
        metrics.record(frameTimestamp: 1.000, now: 0.999)
        let snapshot = try XCTUnwrap(metrics.snapshot(now: 1.100))
        XCTAssertEqual(snapshot.meanDelegateLatencyMs, 0.0, accuracy: 0.01)
        XCTAssertEqual(snapshot.maxDelegateLatencyMs, 0.0, accuracy: 0.01)
    }

    func testResetClearsAllAccumulatedState() {
        var metrics = DelegateFrameMetrics()
        metrics.record(frameTimestamp: 0, now: 0.01)
        metrics.record(frameTimestamp: 0.1, now: 0.12)
        XCTAssertNotNil(metrics.snapshot(now: 0.2))

        metrics.reset()

        XCTAssertNil(metrics.snapshot(now: 0.2))
        XCTAssertEqual(metrics.frameCount, 0)
    }

    func testWindowRestartsFromTheFirstFrameAfterReset() throws {
        var metrics = DelegateFrameMetrics()
        metrics.record(frameTimestamp: 0, now: 0.01)
        metrics.reset()

        // A fresh window starting at t=100, not carrying over the old one —
        // otherwise the next FPS calculation would silently include a huge
        // bogus elapsed time back to the pre-reset window.
        metrics.record(frameTimestamp: 100.0, now: 100.01)
        metrics.record(frameTimestamp: 100.5, now: 100.51)
        let snapshot = try XCTUnwrap(metrics.snapshot(now: 101.0))
        XCTAssertEqual(snapshot.arkitFPS, 2.0, accuracy: 0.01)
    }
}
