import XCTest
@testable import Cotabby

/// Focused coverage for one responsibility of `SuggestionSessionReconciler`.
final class SuggestionSessionTypingTests: XCTestCase {
    func test_advanceIfTypedCharactersMatch_advancesMatchingDirectText() {
        let session = CotabbyTestFixtures.activeSession(fullText: " world again")

        let advanced = SuggestionSessionReconciler.advanceIfTypedCharactersMatch(
            " world",
            session: session
        )

        XCTAssertEqual(advanced?.acceptedText, " world")
        XCTAssertEqual(advanced?.remainingText, " again")
    }

    func test_advanceIfTypedCharactersMatch_returnsNilForDivergentText() {
        let session = CotabbyTestFixtures.activeSession(fullText: " world again")

        let advanced = SuggestionSessionReconciler.advanceIfTypedCharactersMatch(
            " there",
            session: session
        )

        XCTAssertNil(advanced)
    }

    func test_advanceIfTypedCharactersMatch_returnsNilForControlCharacters() {
        let session = CotabbyTestFixtures.activeSession(fullText: " world again")

        let advanced = SuggestionSessionReconciler.advanceIfTypedCharactersMatch(
            "\n",
            session: session
        )

        XCTAssertNil(advanced)
    }

    func test_advanceIfTypedCharactersMatch_returnsNilForEmptyInput() {
        // An empty capture is not a text mutation; advancing by zero would silently re-validate a
        // session that no key event actually confirmed.
        let session = CotabbyTestFixtures.activeSession(fullText: " world again")

        XCTAssertNil(SuggestionSessionReconciler.advanceIfTypedCharactersMatch("", session: session))
    }

    func test_advanceIfTypedCharactersMatch_neverConsumesACorrection() {
        let session = ActiveSuggestionSession(
            baseContext: CotabbyTestFixtures.focusedInputContext(precedingText: "Please recieve "),
            fullText: "receive",
            latency: 0,
            kind: .correction(typoWord: "recieve")
        )

        XCTAssertNil(SuggestionSessionReconciler.advanceIfTypedCharactersMatch("r", session: session))
        XCTAssertNil(SuggestionSessionReconciler.advanceIfTypedCharactersMatch("receive", session: session))
    }

    func test_typedTextCanCrossTheInitialVisibleBoundaryWithoutDiscardingFollowingWords() throws {
        let session = ActiveSuggestionSession(
            baseContext: CotabbyTestFixtures.focusedInputContext(precedingText: "Make a flux"),
            fullText: "beam for the device",
            initialVisibleCharacterCount: 4,
            latency: 0
        )

        let advanced = try XCTUnwrap(SuggestionSessionReconciler.advanceIfTypedCharactersMatch(
            "beam for", session: session
        ))

        XCTAssertEqual(advanced.remainingText, " the device")
        XCTAssertEqual(advanced.consumedCharacterCount, 8)
        XCTAssertFalse(advanced.isExhausted)
    }

    func test_typingThroughOneWordRevealsOnlyTheNextWordInOneWordMode() throws {
        let session = ActiveSuggestionSession(
            baseContext: CotabbyTestFixtures.focusedInputContext(),
            fullText: " hello world again",
            showFollowingWords: false,
            latency: 0
        )

        let advanced = try XCTUnwrap(SuggestionSessionReconciler.advanceIfTypedCharactersMatch(
            " hello ", session: session
        ))

        XCTAssertEqual(advanced.remainingText, "world")
        XCTAssertEqual(advanced.predictedRemainingText, "world again")
    }
}
