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
}
