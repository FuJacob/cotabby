import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for `FocusSessionWalkThrottle`, which collapses the per-keystroke deep caret BFS and the
/// static-text-run walk to at most one walk per interval while focus stays in one field. The walks
/// themselves reach into the live AX tree, but the throttle's caching decision is pure once `now`
/// is injected.
@MainActor
final class FocusSessionWalkThrottleTests: XCTestCase {
    private static let base = Date(timeIntervalSinceReferenceDate: 0)
    private static let interval: TimeInterval = 0.1

    /// Owns one throttle plus a count of how many times its walk actually ran.
    @MainActor
    private struct Harness<Value> {
        let throttle = FocusSessionWalkThrottle<Value>()
        var walkCount = 0

        /// Asks for a value `offset` seconds after `base`; a walk, if it runs, returns `walked`, so
        /// the caller can tell a fresh walk from a cached one.
        mutating func value(sequence: UInt64, at offset: TimeInterval, walked: Value) -> Value {
            var didWalk = false
            let value = throttle.value(
                focusChangeSequence: sequence,
                interval: FocusSessionWalkThrottleTests.interval,
                now: FocusSessionWalkThrottleTests.base.addingTimeInterval(offset)
            ) {
                didWalk = true
                return walked
            }
            if didWalk { walkCount += 1 }
            return value
        }
    }

    func test_firstCallWalks() {
        var h = Harness<Int>()
        XCTAssertEqual(h.value(sequence: 1, at: 0, walked: 10), 10)
        XCTAssertEqual(h.walkCount, 1)
    }

    func test_reusesValueWithinIntervalForTheSameField() {
        var h = Harness<Int>()
        _ = h.value(sequence: 1, at: 0, walked: 10)

        XCTAssertEqual(h.value(sequence: 1, at: 0.05, walked: 20), 10)
        XCTAssertEqual(h.walkCount, 1)
    }

    /// A walk that found nothing is still an answer: re-walking every keystroke for a field with no
    /// deep caret source is exactly the CPU cost the throttle exists to remove.
    func test_reusesANilResultWithinInterval() {
        var h = Harness<CaretGeometryResult?>()
        XCTAssertNil(h.value(sequence: 1, at: 0, walked: nil))

        let fresh = CaretGeometryResult(rect: CGRect(x: 20, y: 0, width: 1, height: 1), quality: .exact)
        XCTAssertNil(h.value(sequence: 1, at: 0.05, walked: fresh))
        XCTAssertEqual(h.walkCount, 1)
    }

    /// The static-run walk's counterpart of a nil result: a field with no static-text children.
    func test_reusesAnEmptyRunListWithinInterval() {
        var h = Harness<[StaticTextRun]>()
        XCTAssertTrue(h.value(sequence: 1, at: 0, walked: []).isEmpty)

        let fresh = [
            StaticTextRun(text: "alpha", frame: CGRect(x: 0, y: 0, width: 50, height: 10), allowsProportionalCaretPlacement: true)
        ]
        XCTAssertTrue(h.value(sequence: 1, at: 0.05, walked: fresh).isEmpty)
        XCTAssertEqual(h.walkCount, 1)
    }

    func test_rewalksOnceTheIntervalHasFullyElapsed() {
        var h = Harness<Int>()
        _ = h.value(sequence: 1, at: 0, walked: 10)

        // The window is half-open: exactly one interval later is already stale.
        XCTAssertEqual(h.value(sequence: 1, at: Self.interval, walked: 20), 20)
        XCTAssertEqual(h.walkCount, 2)
    }

    func test_rewalksImmediatelyOnSequenceChange() {
        var h = Harness<Int>()
        _ = h.value(sequence: 1, at: 0, walked: 10)

        XCTAssertEqual(h.value(sequence: 2, at: 0.01, walked: 20), 20)
        XCTAssertEqual(h.walkCount, 2)
    }

    /// Only the latest field is remembered, so returning to an earlier field walks again rather than
    /// serving geometry measured before the other field was focused.
    func test_returningToAnEarlierFieldRewalks() {
        var h = Harness<Int>()
        _ = h.value(sequence: 1, at: 0, walked: 10)
        _ = h.value(sequence: 2, at: 0.01, walked: 20)

        XCTAssertEqual(h.value(sequence: 1, at: 0.02, walked: 30), 30)
        XCTAssertEqual(h.walkCount, 3)
    }

    /// After Cotabby's own synthetic insert the cached run texts predate the inserted chunk;
    /// invalidation makes the next caller walk fresh frames even though neither the field nor the
    /// window changed.
    func test_invalidate_forcesAFreshWalkInsideTheWindow() {
        var h = Harness<Int>()
        _ = h.value(sequence: 1, at: 0, walked: 10)

        h.throttle.invalidate()

        XCTAssertEqual(h.value(sequence: 1, at: 0.01, walked: 20), 20)
        XCTAssertEqual(h.walkCount, 2)
    }

    /// The exact previous-character bounds and the union frame come from the same AX walk. They
    /// must stay cached together; mixing a fresh frame with stale character geometry would
    /// reintroduce the overlay jump the throttle exists to prevent.
    func test_reusesWrappedRunCharacterBoundsWithTheFrameSnapshot() {
        var h = Harness<[StaticTextRun]>()
        let characterFrame = CGRect(x: 42, y: 20, width: 7, height: 21)
        let wrappedRun = [
            StaticTextRun(
                text: "wrapped text",
                frame: CGRect(x: 0, y: 0, width: 100, height: 42),
                caretCharacterFrame: characterFrame,
                allowsProportionalCaretPlacement: false
            )
        ]
        _ = h.value(sequence: 1, at: 0, walked: wrappedRun)

        let cached = h.value(sequence: 1, at: 0.05, walked: [])

        XCTAssertEqual(cached.first?.caretCharacterFrame, characterFrame)
        XCTAssertEqual(cached.first?.allowsProportionalCaretPlacement, false)
    }
}
