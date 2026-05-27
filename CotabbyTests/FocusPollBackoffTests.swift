import XCTest
@testable import Cotabby

/// Verifies the focus-poll idle backoff schedule (`FocusTracker.captureStride`). This is the #280
/// fix: the poll stays responsive right after activity, then stretches the interval between the
/// expensive Accessibility walks once the focused state stops changing — so an idle machine isn't
/// paying for ~12.5 Chrome AX tree walks per second.
final class FocusPollBackoffTests: XCTestCase {
    func test_recentActivityStaysAtFullCadence() {
        // The first handful of unchanged captures keep stride 1, so a brief pause never feels laggy.
        XCTAssertEqual(FocusTracker.captureStride(idleCaptureCount: 0), 1)
        XCTAssertEqual(FocusTracker.captureStride(idleCaptureCount: 4), 1)
    }

    func test_strideGrowsAsIdlePersists() {
        XCTAssertEqual(FocusTracker.captureStride(idleCaptureCount: 5), 3)
        XCTAssertEqual(FocusTracker.captureStride(idleCaptureCount: 11), 3)
        XCTAssertEqual(FocusTracker.captureStride(idleCaptureCount: 12), 6)
        XCTAssertEqual(FocusTracker.captureStride(idleCaptureCount: 29), 6)
        XCTAssertEqual(FocusTracker.captureStride(idleCaptureCount: 30), 10)
    }

    func test_longIdleCapsStride() {
        // Far past the last threshold the stride holds steady rather than growing without bound.
        XCTAssertEqual(FocusTracker.captureStride(idleCaptureCount: 100), 10)
        XCTAssertEqual(FocusTracker.captureStride(idleCaptureCount: 10_000), 10)
    }

    func test_strideIsMonotonicNonDecreasing() {
        // Backoff must never speed back up on its own; only real activity (an explicit refresh) resets it.
        var previous = 0
        for count in 0...120 {
            let stride = FocusTracker.captureStride(idleCaptureCount: count)
            XCTAssertGreaterThanOrEqual(stride, previous, "stride decreased at idleCaptureCount=\(count)")
            previous = stride
        }
    }
}
