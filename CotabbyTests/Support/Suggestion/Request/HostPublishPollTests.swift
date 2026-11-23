import XCTest
@testable import Cotabby

/// Verifies the timing, the "host moved on" rule, and the step table of the wait between a
/// keystroke and the prediction it schedules. The coordinator tests only reach these through real
/// sleeps.
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

    // MARK: - Step

    func test_aPublishIsSeenEvenOnTheReadThatReachesTheCeiling() {
        let baseline = HostPublishBaseline(snapshot: snapshot("Hello"), requiresTextChange: true)

        XCTAssertEqual(
            baseline.nextStep(after: snapshot("Hello "), awaitingPreparedTarget: false, elapsedMilliseconds: 6),
            .published
        )
        XCTAssertEqual(
            baseline.nextStep(after: snapshot("Hello "), awaitingPreparedTarget: false, elapsedMilliseconds: 390),
            .published
        )
    }

    func test_noChangeKeepsPollingOnTheSchedule() {
        let baseline = HostPublishBaseline(snapshot: snapshot("Hello"), requiresTextChange: false)

        XCTAssertEqual(
            baseline.nextStep(after: snapshot("Hello"), awaitingPreparedTarget: false, elapsedMilliseconds: 6),
            .pollAgain(afterMilliseconds: 8)
        )
        XCTAssertEqual(
            baseline.nextStep(after: snapshot("Hello"), awaitingPreparedTarget: false, elapsedMilliseconds: 200),
            .pollAgain(afterMilliseconds: 30)
        )
    }

    func test_atTheCeilingOrdinaryInputGeneratesAndAReplacementIsAbandoned() {
        let ordinary = HostPublishBaseline(snapshot: snapshot("Hello"), requiresTextChange: false)
        let replacement = HostPublishBaseline(snapshot: snapshot("teh "), requiresTextChange: true)

        XCTAssertEqual(
            ordinary.nextStep(after: snapshot("Hello"), awaitingPreparedTarget: false, elapsedMilliseconds: 390),
            .generateAtCeiling
        )
        XCTAssertEqual(
            replacement.nextStep(after: snapshot("teh "), awaitingPreparedTarget: false, elapsedMilliseconds: 390),
            .abandonAtCeiling
        )
    }

    func test_anAwaitedPreparedTargetHoldsOffIntermediatePublishesUntilTheCeiling() {
        let baseline = HostPublishBaseline(snapshot: snapshot("teh "), requiresTextChange: true)

        // A replacement's backspaces publish before its insert; that slice is not the user's edit.
        XCTAssertEqual(
            baseline.nextStep(after: snapshot("te"), awaitingPreparedTarget: true, elapsedMilliseconds: 14),
            .pollAgain(afterMilliseconds: 8)
        )
        XCTAssertEqual(
            baseline.nextStep(after: snapshot("te"), awaitingPreparedTarget: true, elapsedMilliseconds: 390),
            .abandonAtCeiling
        )
    }
}
