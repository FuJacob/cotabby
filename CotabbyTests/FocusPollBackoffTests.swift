import XCTest
@testable import Cotabby

/// Verifies the focus-poll idle backoff (`FocusPollBackoff`). This is the #280 fix: the poll stays
/// responsive right after activity, then stretches the interval between the expensive Accessibility
/// walks once the focused state stops changing — so an idle machine isn't paying for ~12.5 Chrome AX
/// tree walks per second.
final class FocusPollBackoffTests: XCTestCase {
    /// Drives `count` timer ticks, recording every capture as "no change", and returns the result.
    private func idledBackoff(ticks count: Int) -> FocusPollBackoff {
        var backoff = FocusPollBackoff()
        for _ in 0..<count where backoff.shouldCaptureOnTick() {
            backoff.recordCapture(didChange: false)
        }
        return backoff
    }

    // MARK: - Stride schedule

    func test_recentActivityStaysAtFullCadence() {
        // The first handful of unchanged captures keep stride 1, so a brief pause never feels laggy.
        XCTAssertEqual(FocusPollBackoff.captureStride(idleCaptureCount: 0), 1)
        XCTAssertEqual(FocusPollBackoff.captureStride(idleCaptureCount: 4), 1)
    }

    func test_strideGrowsAsIdlePersists() {
        XCTAssertEqual(FocusPollBackoff.captureStride(idleCaptureCount: 5), 3)
        XCTAssertEqual(FocusPollBackoff.captureStride(idleCaptureCount: 11), 3)
        XCTAssertEqual(FocusPollBackoff.captureStride(idleCaptureCount: 12), 6)
        XCTAssertEqual(FocusPollBackoff.captureStride(idleCaptureCount: 29), 6)
        XCTAssertEqual(FocusPollBackoff.captureStride(idleCaptureCount: 30), 10)
    }

    func test_longIdleCapsStride() {
        XCTAssertEqual(FocusPollBackoff.captureStride(idleCaptureCount: 100), 10)
        XCTAssertEqual(FocusPollBackoff.captureStride(idleCaptureCount: 10_000), 10)
    }

    func test_strideIsMonotonicNonDecreasing() {
        var previous = 0
        for count in 0...120 {
            let stride = FocusPollBackoff.captureStride(idleCaptureCount: count)
            XCTAssertGreaterThanOrEqual(stride, previous, "stride decreased at idleCaptureCount=\(count)")
            previous = stride
        }
    }

    // MARK: - State machine

    func test_capturesEveryTickWhileChanging() {
        var backoff = FocusPollBackoff()
        for _ in 0..<10 {
            XCTAssertTrue(backoff.shouldCaptureOnTick())
            backoff.recordCapture(didChange: true)
        }
        XCTAssertEqual(backoff.idleCaptureCount, 0)
    }

    func test_sustainedIdleStretchesStrideSoMostTicksSkip() {
        var backoff = FocusPollBackoff()
        var captures = 0
        for _ in 0..<400 where backoff.shouldCaptureOnTick() {
            backoff.recordCapture(didChange: false)
            captures += 1
        }
        XCTAssertGreaterThanOrEqual(backoff.idleCaptureCount, 30)
        XCTAssertLessThanOrEqual(backoff.idleCaptureCount, FocusPollBackoff.idleCaptureCountCap)
        // With the stride ramping to 10, 400 ticks should yield far fewer than 400 captures.
        XCTAssertLessThan(captures, 100)
    }

    /// The invariant Greptile flagged: a change after a long idle period must snap back to full
    /// cadence, not stay permanently backed off. (A dropped reset here would leave stride at 10.)
    func test_changeAfterIdleResetsToFullCadence() {
        var backoff = idledBackoff(ticks: 400)
        XCTAssertGreaterThan(FocusPollBackoff.captureStride(idleCaptureCount: backoff.idleCaptureCount), 1)

        while !backoff.shouldCaptureOnTick() {}
        backoff.recordCapture(didChange: true)

        XCTAssertEqual(backoff.idleCaptureCount, 0)
        XCTAssertEqual(FocusPollBackoff.captureStride(idleCaptureCount: backoff.idleCaptureCount), 1)
        XCTAssertTrue(backoff.shouldCaptureOnTick(), "the tick after a change should capture immediately")
    }

    func test_resetReturnsToFullCadence() {
        var backoff = idledBackoff(ticks: 400)
        backoff.reset()
        XCTAssertEqual(backoff.idleCaptureCount, 0)
        XCTAssertTrue(backoff.shouldCaptureOnTick(), "the tick after an explicit refresh should capture immediately")
    }
}
