import XCTest
@testable import Cotabby

/// Tests for the phase model and pacing behind the self-playing onboarding demos.
@MainActor
final class DemoTypingPhaseTests: XCTestCase {
    // MARK: - Phase

    func test_typedCount_followsTypingAndIsCompleteOnceAnOfferExists() {
        XCTAssertEqual(DemoTypingPhase.typing(count: 0).typedCount(outOf: 5), 0)
        XCTAssertEqual(DemoTypingPhase.typing(count: 3).typedCount(outOf: 5), 3)
        XCTAssertEqual(DemoTypingPhase.offered.typedCount(outOf: 5), 5)
        XCTAssertEqual(DemoTypingPhase.accepted.typedCount(outOf: 5), 5)
    }

    func test_typedCount_isClampedToTheText() {
        XCTAssertEqual(DemoTypingPhase.typing(count: 9).typedCount(outOf: 5), 5)
        XCTAssertEqual(DemoTypingPhase.typing(count: -1).typedCount(outOf: 5), 0)
    }

    func test_offerVisibility_distinguishesPendingFromAccepted() {
        let typing = DemoTypingPhase.typing(count: 2)
        XCTAssertFalse(typing.showsOffer)
        XCTAssertFalse(typing.isAwaitingAccept)

        XCTAssertTrue(DemoTypingPhase.offered.showsOffer)
        XCTAssertTrue(DemoTypingPhase.offered.isAwaitingAccept)

        // Accepted keeps the offered text on screen but drops the keycap and pending styling.
        XCTAssertTrue(DemoTypingPhase.accepted.showsOffer)
        XCTAssertFalse(DemoTypingPhase.accepted.isAwaitingAccept)
    }

    // MARK: - Timeline

    private func makeTimeline(pauseBeforeOffer: UInt64 = 0) -> DemoTypingTimeline {
        DemoTypingTimeline(
            emptyHoldMilliseconds: 350,
            perCharacterMilliseconds: 55,
            pauseBeforeOfferMilliseconds: pauseBeforeOffer,
            offerAnimationDuration: 0.18,
            offerHoldMilliseconds: 1300,
            acceptAnimationDuration: 0.22,
            acceptedHoldMilliseconds: 900,
            resetAnimationDuration: 0.30,
            resetHoldMilliseconds: 600
        )
    }

    func test_loop_typesEveryCharacterThenOffersAcceptsAndResets() {
        let steps = makeTimeline().loop(characterCount: 3)

        XCTAssertEqual(steps.map(\.phase), [
            .typing(count: 0),
            .typing(count: 1),
            .typing(count: 2),
            .typing(count: 3),
            .offered,
            .accepted,
            .typing(count: 0)
        ])
    }

    func test_loop_animatesOnlyTheOfferAcceptAndResetTransitions() {
        let steps = makeTimeline().loop(characterCount: 2)

        // Typing must snap: animating each character would smear the text as it appears.
        XCTAssertEqual(steps.map(\.animationDuration), [nil, nil, nil, 0.18, 0.22, 0.30])
    }

    func test_loop_holdsEachStepForItsConfiguredTime() {
        let steps = makeTimeline().loop(characterCount: 2)

        XCTAssertEqual(steps.map(\.holdMilliseconds), [350, 55, 55, 1300, 900, 600])
    }

    func test_loop_addsThePreOfferPauseToTheLastCharacterOnly() {
        let steps = makeTimeline(pauseBeforeOffer: 450).loop(characterCount: 3)

        XCTAssertEqual(steps.map(\.holdMilliseconds), [350, 55, 55, 505, 1300, 900, 600])
    }

    func test_loop_withNoCharactersStillOffersAndResets() {
        let steps = makeTimeline().loop(characterCount: 0)

        XCTAssertEqual(steps.map(\.phase), [.typing(count: 0), .offered, .accepted, .typing(count: 0)])
    }

    func test_startDelay_isNotPartOfTheRepeatingLoop() {
        var timeline = makeTimeline()
        let withoutDelay = timeline.loop(characterCount: 4)

        timeline.startDelayMilliseconds = 1100

        XCTAssertEqual(timeline.loop(characterCount: 4), withoutDelay)
    }
}
