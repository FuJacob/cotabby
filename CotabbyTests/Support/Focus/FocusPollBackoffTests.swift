import XCTest
@testable import Cotabby

/// Verifies the focus-poll idle backoff (`FocusPollBackoff`). This is the #280 fix plus its energy
/// follow-up: the poll stays responsive right after activity, then stretches the interval between the
/// expensive Accessibility walks once the focused state stops changing, so an idle machine isn't
/// waking the main thread ~12.5x/second for a walk it would only skip.
final class FocusPollBackoffTests: XCTestCase {
    /// Returns a backoff that has recorded `count` consecutive no-change captures (i.e. gone idle).
    private func idledBackoff(captures count: Int) -> FocusPollBackoff {
        var backoff = FocusPollBackoff()
        for _ in 0..<count {
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

    func test_instanceStrideMatchesSchedule() {
        XCTAssertEqual(FocusPollBackoff().captureStride, 1)
        XCTAssertEqual(idledBackoff(captures: 5).captureStride, 3)
        XCTAssertEqual(idledBackoff(captures: 12).captureStride, 6)
        XCTAssertEqual(idledBackoff(captures: 30).captureStride, 10)
    }

    func test_capturesWhileChangingStayAtFullCadence() {
        var backoff = FocusPollBackoff()
        for _ in 0..<10 {
            backoff.recordCapture(didChange: true)
        }
        XCTAssertEqual(backoff.idleCaptureCount, 0)
        XCTAssertEqual(backoff.captureStride, 1)
    }

    func test_sustainedIdleGrowsStrideAndCaps() {
        let backoff = idledBackoff(captures: 400)
        XCTAssertEqual(backoff.idleCaptureCount, FocusPollBackoff.idleCaptureCountCap)
        XCTAssertEqual(backoff.captureStride, 10)
    }

    /// The invariant Greptile flagged: a change after a long idle period must snap back to full
    /// cadence, not stay permanently backed off. (A dropped reset here would leave the stride at 10.)
    func test_changeAfterIdleResetsToFullCadence() {
        var backoff = idledBackoff(captures: 400)
        XCTAssertGreaterThan(backoff.captureStride, 1)

        backoff.recordCapture(didChange: true)

        XCTAssertEqual(backoff.idleCaptureCount, 0)
        XCTAssertEqual(backoff.captureStride, 1)
    }

    func test_resetReturnsToFullCadence() {
        var backoff = idledBackoff(captures: 400)
        backoff.reset()
        XCTAssertEqual(backoff.idleCaptureCount, 0)
        XCTAssertEqual(backoff.captureStride, 1)
    }
}
