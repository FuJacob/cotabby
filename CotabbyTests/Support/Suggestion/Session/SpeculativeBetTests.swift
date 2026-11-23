import XCTest
@testable import Cotabby

/// Verifies the transitions of the speculative bet: which live text pays it off, when a finished
/// result is parked instead of judged, and that a parked result never outlives its bet.
@MainActor
final class SpeculativeBetTests: XCTestCase {
    private var expected: FocusedInputContext {
        CotabbyTestFixtures.focusedInputContext(precedingText: "Hello world ", windowTitle: "Thread A", generation: 7)
    }

    private var result: SuggestionResult {
        SuggestionResult(generation: 7, rawText: "again", text: "again", latency: 0.1)
    }

    func test_idleBetIsNeverPaidOffAndParksNothing() {
        var bet = SpeculativeBet.idle

        XCTAssertNil(bet.expected)
        XCTAssertFalse(bet.isPaidOff(by: expected))
        XCTAssertFalse(bet.park(result, workID: 3, live: expected))
        XCTAssertNil(bet.takeParked())
        XCTAssertEqual(bet, .idle)
    }

    func test_betIsPaidOffByTheSpeculatedTextAtAnyGeneration() {
        var bet = SpeculativeBet.idle
        bet.place(expecting: expected)

        let live = CotabbyTestFixtures.focusedInputContext(
            precedingText: "Hello world ", windowTitle: "Thread A", generation: 12
        )
        XCTAssertTrue(bet.isPaidOff(by: live))
        XCTAssertTrue(bet.isPaidOff(by: CotabbyTestFixtures.focusedInputSnapshot(
            precedingText: "Hello world ", windowTitle: "Thread A"
        )))
    }

    func test_betIsNotPaidOffByDifferentTextOrAnotherConversation() {
        var bet = SpeculativeBet.idle
        bet.place(expecting: expected)

        XCTAssertFalse(bet.isPaidOff(by: CotabbyTestFixtures.focusedInputContext(
            precedingText: "Hello worl", windowTitle: "Thread A"
        )))
        XCTAssertFalse(bet.isPaidOff(by: CotabbyTestFixtures.focusedInputContext(
            precedingText: "Hello world ", windowTitle: "Thread B"
        )))
        XCTAssertFalse(bet.isPaidOff(by: CotabbyTestFixtures.focusedInputContext(
            precedingText: "Hello world ", focusChangeSequence: 2, windowTitle: "Thread A"
        )))
    }

    func test_anUnreadableSurfaceFactStillPaysOffButDoesNotCoverAStreamedPartial() {
        var bet = SpeculativeBet.idle
        bet.place(expecting: expected)
        let titleUnread = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello world ", generation: 12)

        XCTAssertTrue(bet.isPaidOff(by: titleUnread))
        XCTAssertFalse(bet.coversStreamedPartial(generation: 7, in: titleUnread))
    }

    func test_streamedPartialIsCoveredOnlyForTheBetsOwnGenerationOnTheSpeculatedText() {
        var bet = SpeculativeBet.idle
        bet.place(expecting: expected)
        let live = CotabbyTestFixtures.focusedInputContext(
            precedingText: "Hello world ", windowTitle: "Thread A", generation: 12
        )

        XCTAssertTrue(bet.coversStreamedPartial(generation: 7, in: live))
        XCTAssertFalse(bet.coversStreamedPartial(generation: 8, in: live))
        XCTAssertFalse(bet.coversStreamedPartial(generation: 7, in: CotabbyTestFixtures.focusedInputContext(
            precedingText: "Hello worl", windowTitle: "Thread A", generation: 12
        )))
    }

    func test_ownResultFinishingBeforeThePublishIsParkedAndReplayedOnce() {
        var bet = SpeculativeBet.idle
        bet.place(expecting: expected)
        let unpublished = CotabbyTestFixtures.focusedInputContext(
            precedingText: "Hello worl", windowTitle: "Thread A", generation: 6
        )

        XCTAssertTrue(bet.park(result, workID: 3, live: unpublished))
        XCTAssertEqual(bet, .parked(expected: expected, result: result, workID: 3))

        let parked = bet.takeParked()
        XCTAssertEqual(parked?.result, result)
        XCTAssertEqual(parked?.workID, 3)
        XCTAssertEqual(bet, .awaitingPublish(expected: expected), "The replayed result still needs the bet to pass as current")
        XCTAssertNil(bet.takeParked())
    }

    func test_resultsOfAnotherRequestOrConversationAreNotParked() {
        var bet = SpeculativeBet.idle
        bet.place(expecting: expected)
        let unpublished = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello worl", windowTitle: "Thread A")
        let otherRequest = SuggestionResult(generation: 6, rawText: "x", text: "x", latency: 0.1)

        XCTAssertFalse(bet.park(otherRequest, workID: 3, live: unpublished))
        XCTAssertFalse(bet.park(result, workID: 3, live: CotabbyTestFixtures.focusedInputContext(
            precedingText: "Hello worl", windowTitle: "Thread B"
        )))
        XCTAssertEqual(bet, .awaitingPublish(expected: expected))
    }

    func test_aNewBetOrAClearDropsTheParkedResult() {
        var bet = SpeculativeBet.idle
        bet.place(expecting: expected)
        XCTAssertTrue(bet.park(result, workID: 3, live: expected))

        var replaced = bet
        let next = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello world again", generation: 9)
        replaced.place(expecting: next)
        XCTAssertEqual(replaced, .awaitingPublish(expected: next))
        XCTAssertNil(replaced.takeParked())

        bet.clear()
        XCTAssertEqual(bet, .idle)
        XCTAssertNil(bet.takeParked())
    }
}
