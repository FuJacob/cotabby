import XCTest
@testable import Cotabby

/// Tests for the Branch 2.5 run-walk throttle, mirroring `DeepGeometryWalkThrottleTests`: reuse
/// within the window on one field, fresh walk after the window, and an immediate fresh walk on a
/// field switch regardless of elapsed time.
@MainActor
final class StaticTextRunWalkThrottleTests: XCTestCase {
    private let runA = [
        StaticTextRunWalkThrottle.TextRun(
            text: "alpha",
            frame: CGRect(x: 0, y: 0, width: 50, height: 10)
        )
    ]
    private let runB = [
        StaticTextRunWalkThrottle.TextRun(
            text: "beta",
            frame: CGRect(x: 0, y: 10, width: 40, height: 10)
        )
    ]

    func test_reusesRunsWithinWindowForSameField() {
        let throttle = StaticTextRunWalkThrottle()
        let start = Date(timeIntervalSinceReferenceDate: 100)
        var walkCount = 0

        let first = throttle.runs(focusChangeSequence: 1, interval: 0.1, now: start) {
            walkCount += 1
            return runA
        }
        let second = throttle.runs(
            focusChangeSequence: 1,
            interval: 0.1,
            now: start.addingTimeInterval(0.05)
        ) {
            walkCount += 1
            return runB
        }

        XCTAssertEqual(walkCount, 1)
        XCTAssertEqual(first.map(\.text), ["alpha"])
        XCTAssertEqual(second.map(\.text), ["alpha"])
    }

    func test_walksAgainAfterWindowElapses() {
        let throttle = StaticTextRunWalkThrottle()
        let start = Date(timeIntervalSinceReferenceDate: 100)
        var walkCount = 0

        _ = throttle.runs(focusChangeSequence: 1, interval: 0.1, now: start) {
            walkCount += 1
            return runA
        }
        let second = throttle.runs(
            focusChangeSequence: 1,
            interval: 0.1,
            now: start.addingTimeInterval(0.11)
        ) {
            walkCount += 1
            return runB
        }

        XCTAssertEqual(walkCount, 2)
        XCTAssertEqual(second.map(\.text), ["beta"])
    }

    func test_fieldSwitchForcesImmediateFreshWalk() {
        let throttle = StaticTextRunWalkThrottle()
        let start = Date(timeIntervalSinceReferenceDate: 100)
        var walkCount = 0

        _ = throttle.runs(focusChangeSequence: 1, interval: 0.1, now: start) {
            walkCount += 1
            return runA
        }
        let second = throttle.runs(
            focusChangeSequence: 2,
            interval: 0.1,
            now: start.addingTimeInterval(0.01)
        ) {
            walkCount += 1
            return runB
        }

        XCTAssertEqual(walkCount, 2)
        XCTAssertEqual(second.map(\.text), ["beta"])
    }

    func test_cachesEmptyWalkResultWithinWindow() {
        let throttle = StaticTextRunWalkThrottle()
        let start = Date(timeIntervalSinceReferenceDate: 100)
        var walkCount = 0

        let first = throttle.runs(focusChangeSequence: 1, interval: 0.1, now: start) {
            walkCount += 1
            return []
        }
        let second = throttle.runs(
            focusChangeSequence: 1,
            interval: 0.1,
            now: start.addingTimeInterval(0.05)
        ) {
            walkCount += 1
            return runA
        }

        XCTAssertEqual(walkCount, 1)
        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(second.isEmpty)
    }

    func test_invalidate_forcesAFreshWalkInsideTheWindow() {
        // After Cotabby's own synthetic insert the cached run texts predate the inserted chunk;
        // invalidation makes the next caller walk fresh frames even though neither the field nor
        // the window changed.
        let throttle = StaticTextRunWalkThrottle()
        let start = Date(timeIntervalSinceReferenceDate: 100)
        var walkCount = 0

        _ = throttle.runs(focusChangeSequence: 1, interval: 0.1, now: start) {
            walkCount += 1
            return runA
        }
        throttle.invalidate()
        let afterInvalidation = throttle.runs(
            focusChangeSequence: 1,
            interval: 0.1,
            now: start.addingTimeInterval(0.01)
        ) {
            walkCount += 1
            return runB
        }

        XCTAssertEqual(walkCount, 2)
        XCTAssertEqual(afterInvalidation.map(\.text), ["beta"])
    }

    func test_reusesWrappedRunCharacterBoundsWithTheFrameSnapshot() {
        // The exact previous-character bounds and the union frame come from the same AX walk.
        // They must stay cached together; mixing a fresh frame with stale character geometry would
        // reintroduce the overlay jump this throttle exists to prevent.
        let throttle = StaticTextRunWalkThrottle()
        let start = Date(timeIntervalSinceReferenceDate: 100)
        let characterFrame = CGRect(x: 42, y: 20, width: 7, height: 21)
        let wrappedRun = [
            StaticTextRunWalkThrottle.TextRun(
                text: "wrapped text",
                frame: CGRect(x: 0, y: 0, width: 100, height: 42),
                caretCharacterFrame: characterFrame
            )
        ]

        _ = throttle.runs(focusChangeSequence: 1, interval: 0.1, now: start) {
            wrappedRun
        }
        let cached = throttle.runs(
            focusChangeSequence: 1,
            interval: 0.1,
            now: start.addingTimeInterval(0.05)
        ) {
            runA
        }

        XCTAssertEqual(cached.first?.caretCharacterFrame, characterFrame)
    }
}
