import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for `DeepGeometryWalkThrottle`, which collapses the per-keystroke deep caret BFS to at most
/// one walk per interval while focus stays in one field. The walk itself reaches into the live AX
/// tree, but the throttle's caching decision is pure once `now` is injected.
@MainActor
final class DeepGeometryWalkThrottleTests: XCTestCase {
    private static let base = Date(timeIntervalSinceReferenceDate: 0)
    private static let interval: TimeInterval = 0.1

    /// Owns one throttle plus a count of how many times its walk actually ran.
    @MainActor
    private struct Harness {
        let throttle: DeepGeometryWalkThrottle
        var walkCount = 0

        /// Asks for a result `offset` seconds after `base`; a walk, if it runs, returns a rect whose
        /// `minX` is `walkX`, so the caller can tell a fresh walk from a cached one.
        mutating func result(sequence: UInt64, at offset: TimeInterval, walkX: CGFloat?) -> CGFloat? {
            var didWalk = false
            let minX = throttle.result(
                focusChangeSequence: sequence,
                interval: DeepGeometryWalkThrottleTests.interval,
                now: DeepGeometryWalkThrottleTests.base.addingTimeInterval(offset)
            ) {
                didWalk = true
                return walkX.map { CaretGeometryResult(rect: CGRect(x: $0, y: 0, width: 1, height: 1), quality: .exact) }
            }?.rect.minX
            if didWalk { walkCount += 1 }
            return minX
        }
    }

    private func makeHarness() -> Harness {
        Harness(throttle: DeepGeometryWalkThrottle())
    }

    func test_firstCallWalks() {
        var h = makeHarness()
        XCTAssertEqual(h.result(sequence: 1, at: 0, walkX: 10), 10)
        XCTAssertEqual(h.walkCount, 1)
    }

    func test_reusesResultWithinIntervalForTheSameField() {
        var h = makeHarness()
        _ = h.result(sequence: 1, at: 0, walkX: 10)

        XCTAssertEqual(h.result(sequence: 1, at: 0.05, walkX: 20), 10)
        XCTAssertEqual(h.walkCount, 1)
    }

    /// A walk that found nothing is still an answer: re-walking every keystroke for a field with no
    /// deep caret source is exactly the CPU cost the throttle exists to remove.
    func test_reusesANilResultWithinInterval() {
        var h = makeHarness()
        XCTAssertNil(h.result(sequence: 1, at: 0, walkX: nil))

        XCTAssertNil(h.result(sequence: 1, at: 0.05, walkX: 20))
        XCTAssertEqual(h.walkCount, 1)
    }

    func test_rewalksOnceTheIntervalHasFullyElapsed() {
        var h = makeHarness()
        _ = h.result(sequence: 1, at: 0, walkX: 10)

        // The window is half-open: exactly one interval later is already stale.
        XCTAssertEqual(h.result(sequence: 1, at: Self.interval, walkX: 20), 20)
        XCTAssertEqual(h.walkCount, 2)
    }

    func test_rewalksImmediatelyOnSequenceChange() {
        var h = makeHarness()
        _ = h.result(sequence: 1, at: 0, walkX: 10)

        XCTAssertEqual(h.result(sequence: 2, at: 0.01, walkX: 20), 20)
        XCTAssertEqual(h.walkCount, 2)
    }

    /// Only the latest field is remembered, so returning to an earlier field walks again rather than
    /// serving geometry measured before the other field was focused.
    func test_returningToAnEarlierFieldRewalks() {
        var h = makeHarness()
        _ = h.result(sequence: 1, at: 0, walkX: 10)
        _ = h.result(sequence: 2, at: 0.01, walkX: 20)

        XCTAssertEqual(h.result(sequence: 1, at: 0.02, walkX: 30), 30)
        XCTAssertEqual(h.walkCount, 3)
    }
}
