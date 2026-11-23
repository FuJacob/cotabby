import AppKit
import XCTest
@testable import Cotabby

/// Tests for the active suggestion session value: how much of a prediction is consumed, which part
/// is offered next, and when a session may be extended. Small rules, but the coordinator slices
/// every accepted chunk through them, so an off-by-one here inserts the wrong text.
final class ActiveSuggestionSessionTests: XCTestCase {
    func test_activeSuggestionSession_clampsConsumedCountAndSlicesByCharacters() {
        let overConsumed = CotabbyTestFixtures.activeSession(fullText: "hello", consumedCharacterCount: 99)
        XCTAssertEqual(overConsumed.acceptedText, "hello")
        XCTAssertEqual(overConsumed.remainingText, "")
        XCTAssertTrue(overConsumed.isExhausted)

        // A negative count (e.g. a stale reconciliation delta) must clamp to the start, not index
        // before the string.
        let underConsumed = CotabbyTestFixtures.activeSession(fullText: "hello", consumedCharacterCount: -4)
        XCTAssertEqual(underConsumed.consumedCharacterCount, 0)
        XCTAssertEqual(underConsumed.remainingText, "hello")
    }

    func test_activeSuggestionSession_advancingByNegativeCountIsANoOp() {
        let session = CotabbyTestFixtures.activeSession(fullText: "hello", consumedCharacterCount: 2)

        XCTAssertEqual(session.advancing(by: -3).consumedCharacterCount, 2)
    }

    func test_activeSuggestionSession_whitespaceOnlyTailCountsAsExhausted() {
        // Ghost spaces are visually confusing, so a tail of only whitespace ends the session.
        let session = CotabbyTestFixtures.activeSession(fullText: "hello \n ", consumedCharacterCount: 5)

        XCTAssertTrue(session.isExhausted)
    }

    func test_activeSuggestionSession_clampsInitialVisibleBoundaryToTheText() {
        let session = ActiveSuggestionSession(
            baseContext: CotabbyTestFixtures.focusedInputContext(),
            fullText: "abc",
            initialVisibleCharacterCount: 99,
            latency: 0
        )

        XCTAssertEqual(session.initialVisibleCharacterCount, 3)
        XCTAssertEqual(session.remainingText, "abc")
        XCTAssertEqual(session.predictedRemainingText, "abc")
    }

    func test_activeSuggestionSession_retainsFollowingWordsBehindAnInitialWordEnding() {
        let session = ActiveSuggestionSession(
            baseContext: CotabbyTestFixtures.focusedInputContext(precedingText: "Build a flux"),
            fullText: "beam for the device",
            initialVisibleCharacterCount: 4,
            latency: 0.05
        )

        XCTAssertEqual(session.remainingText, "beam")
        XCTAssertEqual(session.predictedRemainingText, "beam for the device")

        let partlyTyped = session.advancing(by: 2)
        XCTAssertEqual(partlyTyped.remainingText, "am")
        XCTAssertEqual(partlyTyped.predictedRemainingText, "am for the device")

        let completedWord = partlyTyped.advancing(by: 2)
        XCTAssertEqual(completedWord.remainingText, " for the device")
        XCTAssertEqual(completedWord.predictedRemainingText, " for the device")
        XCTAssertFalse(completedWord.isExhausted)
        XCTAssertEqual(completedWord.baseContext, session.baseContext)
    }

    func test_activeSuggestionSession_oneWordPresentationRollsThroughTheSamePrediction() {
        var session = ActiveSuggestionSession(
            baseContext: CotabbyTestFixtures.focusedInputContext(),
            fullText: " hello world again",
            showFollowingWords: false,
            latency: 0.05
        )

        for expectedOffer in [" hello", " world", " again"] {
            XCTAssertEqual(session.remainingText, expectedOffer)
            XCTAssertFalse(session.isExhausted)
            session = session.advancing(by: expectedOffer.count)
        }
        XCTAssertTrue(session.isExhausted)
        XCTAssertEqual(session.remainingText, "")
    }

    func test_activeSuggestionSession_initialBoundaryCountsGraphemes() {
        let session = ActiveSuggestionSession(
            baseContext: CotabbyTestFixtures.focusedInputContext(),
            fullText: "é👩🏽‍💻 next",
            initialVisibleCharacterCount: 2,
            latency: 0
        )

        XCTAssertEqual(session.remainingText, "é👩🏽‍💻")
        XCTAssertEqual(session.advancing(by: 1).remainingText, "👩🏽‍💻")
        XCTAssertEqual(session.withConsumedCharacters(2).remainingText, " next")
    }

    func test_activeSuggestionSession_extensionPreservesPresentationAndConsumedPosition() throws {
        let session = ActiveSuggestionSession(
            baseContext: CotabbyTestFixtures.focusedInputContext(),
            fullText: "hello",
            initialVisibleCharacterCount: 5,
            showFollowingWords: false,
            consumedCharacterCount: 2,
            latency: 0.05
        )
        let extended = try XCTUnwrap(session.extendingPrediction(to: "hello world again"))

        XCTAssertEqual(extended.consumedCharacterCount, 2)
        XCTAssertEqual(extended.remainingText, "llo")
        XCTAssertEqual(extended.predictedRemainingText, "llo world again")
        XCTAssertEqual(extended.advancing(by: 3).remainingText, " world")
        XCTAssertEqual(extended.latency, session.latency)
        XCTAssertNil(session.extendingPrediction(to: "help instead"))
    }

    func test_activeSuggestionSession_unrestrictedExtensionImmediatelyOffersTheWholeTail() throws {
        let session = ActiveSuggestionSession(
            baseContext: CotabbyTestFixtures.focusedInputContext(),
            fullText: "hello",
            latency: 0
        )

        XCTAssertEqual(try XCTUnwrap(session.extendingPrediction(to: "hello world")).remainingText, "hello world")
    }

    func test_activeSuggestionSession_correctionsNeverExtend() {
        // A correction commits as a whole-word replacement; streaming extra text onto it would turn
        // the replacement into a forward continuation.
        let correction = ActiveSuggestionSession(
            baseContext: CotabbyTestFixtures.focusedInputContext(precedingText: "teh"),
            fullText: "the",
            latency: 0,
            kind: .correction(typoWord: "teh")
        )

        XCTAssertNil(correction.extendingPrediction(to: "the end"))
        XCTAssertEqual(correction.advancing(by: 1).kind, .correction(typoWord: "teh"))
    }
}
