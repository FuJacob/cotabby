import XCTest
@testable import Cotabby

/// Tests for the Branch 2.5 run-walk throttle, mirroring `DeepGeometryWalkThrottleTests`: reuse
/// within the window on one field, fresh walk after the window, and an immediate fresh walk on a
/// field switch regardless of elapsed time.
@MainActor
final class StaticTextRunWalkThrottleTests: XCTestCase {
    private let runA: [StaticTextRunWalkThrottle.TextRun] = [("alpha", CGRect(x: 0, y: 0, width: 50, height: 10))]
    private let runB: [StaticTextRunWalkThrottle.TextRun] = [("beta", CGRect(x: 0, y: 10, width: 40, height: 10))]

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
}
