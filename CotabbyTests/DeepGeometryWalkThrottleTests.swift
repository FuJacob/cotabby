import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for `DeepGeometryWalkThrottle`, which collapses the per-keystroke deep caret BFS to at most
/// one walk per interval while focus stays in one field. The walk itself reaches into the live AX
/// tree, but the throttle's caching decision is pure once `now` is injected, so it is verified here
/// without any AX dependency. This is net-new coverage: the throttle had no unit test before it was
/// extracted from `FocusSnapshotResolver`.
@MainActor
final class DeepGeometryWalkThrottleTests: XCTestCase {

    // Run `async` (without awaiting) to match the other app-hosted tests: a synchronous @MainActor
    // test blocks the main actor while the host app finishes its own startup.

    func test_result_runsWalkOnFirstCall() async {
        let throttle = DeepGeometryWalkThrottle()
        var calls = 0

        let result = throttle.result(focusChangeSequence: 1, interval: 0.1, now: Self.base) {
            calls += 1
            return Self.makeResult(10)
        }

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result?.rect.minX, 10)
    }

    func test_result_reusesCachedResultWithinInterval() async {
        let throttle = DeepGeometryWalkThrottle()
        var calls = 0
        _ = throttle.result(focusChangeSequence: 1, interval: 0.1, now: Self.base) {
            calls += 1
            return Self.makeResult(10)
        }

        // Same field (sequence) 50ms later, inside the 100ms window: cached, walk not re-run.
        let result = throttle.result(
            focusChangeSequence: 1,
            interval: 0.1,
            now: Self.base.addingTimeInterval(0.05)
        ) {
            calls += 1
            return Self.makeResult(20)
        }

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result?.rect.minX, 10)
    }

    func test_result_rewalksAfterIntervalElapses() async {
        let throttle = DeepGeometryWalkThrottle()
        var calls = 0
        _ = throttle.result(focusChangeSequence: 1, interval: 0.1, now: Self.base) {
            calls += 1
            return Self.makeResult(10)
        }

        // Same field, 150ms later: the window has elapsed, so the walk re-runs.
        let result = throttle.result(
            focusChangeSequence: 1,
            interval: 0.1,
            now: Self.base.addingTimeInterval(0.15)
        ) {
            calls += 1
            return Self.makeResult(20)
        }

        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result?.rect.minX, 20)
    }

    func test_result_rewalksImmediatelyOnSequenceChange() async {
        let throttle = DeepGeometryWalkThrottle()
        var calls = 0
        _ = throttle.result(focusChangeSequence: 1, interval: 0.1, now: Self.base) {
            calls += 1
            return Self.makeResult(10)
        }

        // A different sequence is a real field switch: re-walk immediately even inside the window.
        let result = throttle.result(
            focusChangeSequence: 2,
            interval: 0.1,
            now: Self.base.addingTimeInterval(0.01)
        ) {
            calls += 1
            return Self.makeResult(20)
        }

        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result?.rect.minX, 20)
    }

    // MARK: - helpers

    private static let base = Date(timeIntervalSinceReferenceDate: 0)

    private static func makeResult(_ originX: CGFloat) -> CaretGeometryResult {
        CaretGeometryResult(rect: CGRect(x: originX, y: 0, width: 1, height: 1), quality: .exact)
    }
}
