import XCTest
@testable import Cotabby

/// Verifies the timing and the "host moved on" rule of the wait between a keystroke and the
/// prediction it schedules. The coordinator tests only reach these through real sleeps.
@MainActor
final class HostPublishPollTests: XCTestCase {
    // MARK: - Schedule

    func test_pollsDenselyWhileNativeHostsUsuallyPublish() {
        XCTAssertEqual(HostPublishPollSchedule.nextInterval(afterElapsedMilliseconds: 6), 8)
        XCTAssertEqual(HostPublishPollSchedule.nextInterval(afterElapsedMilliseconds: 54), 8)
    }

    func test_backsOffToTheSteadyIntervalAfterTheDensePhase() {
        XCTAssertEqual(HostPublishPollSchedule.nextInterval(afterElapsedMilliseconds: 62), 30)
        XCTAssertEqual(HostPublishPollSchedule.nextInterval(afterElapsedMilliseconds: 200), 30)
    }

    func test_stopsWhenAnotherPollWouldReachTheCeiling() {
        XCTAssertEqual(HostPublishPollSchedule.nextInterval(afterElapsedMilliseconds: 369), 30)
        XCTAssertNil(HostPublishPollSchedule.nextInterval(afterElapsedMilliseconds: 370))
        XCTAssertNil(HostPublishPollSchedule.nextInterval(afterElapsedMilliseconds: 400))
    }

    func test_aFullWaitStaysUnderTheCeilingAndEnds() {
        var elapsed = HostPublishPollSchedule.firstIntervalMilliseconds
        var polls = 1
        while let interval = HostPublishPollSchedule.nextInterval(afterElapsedMilliseconds: elapsed) {
            elapsed += interval
            polls += 1
            XCTAssertLessThan(polls, 100, "The schedule must terminate")
        }

        XCTAssertLessThan(elapsed, HostPublishPollSchedule.waitCeilingMilliseconds)
        XCTAssertGreaterThan(elapsed, HostPublishPollSchedule.waitCeilingMilliseconds - 30)
        // 6, then 8 ms steps through 62 ms, then 30 ms steps: 1 + 7 + 11 reads at most.
        XCTAssertEqual(polls, 19)
    }

    // MARK: - Baseline

    private func snapshot(
        _ precedingText: String, element: String = "field", selection: Int? = nil
    ) -> FocusedInputSnapshot {
        CotabbyTestFixtures.focusedInputSnapshot(
            elementIdentifier: element,
            precedingText: precedingText,
            selection: selection.map { NSRange(location: $0, length: 0) }
        )
    }

    func test_unchangedSnapshotHasNotMovedOn() {
        let baseline = HostPublishBaseline(snapshot: snapshot("Hello"), requiresTextChange: false)

        XCTAssertFalse(baseline.hostMovedOn(to: snapshot("Hello")))
    }

    func test_ordinaryKeystrokeAcceptsNewTextACaretMoveOrANewElement() {
        let baseline = HostPublishBaseline(snapshot: snapshot("Hello"), requiresTextChange: false)

        XCTAssertTrue(baseline.hostMovedOn(to: snapshot("Hello ")))
        XCTAssertTrue(baseline.hostMovedOn(to: snapshot("Hello", selection: 2)))
        XCTAssertTrue(baseline.hostMovedOn(to: snapshot("Hello", element: "other")))
    }

    func test_replacementCountsOnlyNewText() {
        let baseline = HostPublishBaseline(snapshot: snapshot("teh "), requiresTextChange: true)

        XCTAssertFalse(baseline.hostMovedOn(to: snapshot("teh ", element: "recycled-wrapper")))
        XCTAssertFalse(baseline.hostMovedOn(to: snapshot("teh ", selection: 1)))
        XCTAssertTrue(baseline.hostMovedOn(to: snapshot("the ")))
    }

    func test_losingTheFieldCountsAsMovingOn() {
        let ordinary = HostPublishBaseline(snapshot: snapshot("Hello"), requiresTextChange: false)
        let replacement = HostPublishBaseline(snapshot: snapshot("Hello"), requiresTextChange: true)

        XCTAssertTrue(ordinary.hostMovedOn(to: nil))
        XCTAssertTrue(replacement.hostMovedOn(to: nil))
    }

    func test_noFieldAtKeystrokeTimeWaitsForOneToAppear() {
        let baseline = HostPublishBaseline(snapshot: nil, requiresTextChange: false)

        XCTAssertFalse(baseline.hostMovedOn(to: nil))
        XCTAssertTrue(baseline.hostMovedOn(to: snapshot("Hello")))
    }
}
