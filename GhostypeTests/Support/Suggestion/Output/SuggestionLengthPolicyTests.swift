import XCTest
@testable import Ghostype

final class SuggestionLengthPolicyTests: XCTestCase {
    func testTextWithinTheWindowIsUntouched() {
        XCTAssertEqual(SuggestionLengthPolicy.trimmed(" for your help.", minimum: 4, maximum: 7), " for your help.")
        XCTAssertEqual(SuggestionLengthPolicy.trimmed(" one two three four five six seven", minimum: 4, maximum: 7), " one two three four five six seven")
    }

    func testTextPastTheMaximumIsCutAtAWordBoundary() {
        XCTAssertEqual(
            SuggestionLengthPolicy.trimmed(" I've been thinking about this for a while now", minimum: 4, maximum: 7),
            " I've been thinking about this for a"
        )
    }

    func testAClauseBoundaryInsideTheWindowIsPreferred() {
        // "…later today," ends the fifth word: a natural pause inside 4...7 beats a hard cut at 7.
        XCTAssertEqual(
            SuggestionLengthPolicy.trimmed(" and I will send it later today, once the numbers are in", minimum: 4, maximum: 7),
            " and I will send it later today,"
        )
    }

    func testAClauseBoundaryBeforeTheMinimumIsIgnored() {
        XCTAssertEqual(
            SuggestionLengthPolicy.trimmed(" yes, and the rest of the report is ready now", minimum: 4, maximum: 7),
            " yes, and the rest of the report"
        )
    }

    func testLeadingWhitespaceSurvives() {
        XCTAssertEqual(SuggestionLengthPolicy.trimmed(" a b c d e f g h", minimum: 2, maximum: 4), " a b c d")
    }

    // MARK: - Current word only

    func testCurrentWordOnlyFinishesTheWordAndStopsThere() {
        XCTAssertEqual(SuggestionLengthPolicy.currentWordOnly("lo world, again", precedingText: "Say hel"), "lo")
        XCTAssertEqual(SuggestionLengthPolicy.currentWordOnly("t's fine", precedingText: "it isn"), "t's")
        XCTAssertEqual(SuggestionLengthPolicy.currentWordOnly("ing.", precedingText: "We are meet"), "ing")
        XCTAssertEqual(SuggestionLengthPolicy.currentWordOnly("' t", precedingText: "don"), "", "a dangling connector is not a word ending")
    }

    func testCurrentWordOnlyNeverStartsTheNextWord() {
        XCTAssertEqual(SuggestionLengthPolicy.currentWordOnly(" world", precedingText: "hello"), "")
        XCTAssertEqual(SuggestionLengthPolicy.currentWordOnly("world", precedingText: "hello "), "", "after a space")
        XCTAssertEqual(SuggestionLengthPolicy.currentWordOnly("and", precedingText: "yes,"), "", "after punctuation")
        XCTAssertEqual(SuggestionLengthPolicy.currentWordOnly("bar()", precedingText: "foo.ba"), "", "code-like tokens")
    }

    func testNormalizerAppliesCurrentWordOnly() {
        let request = CotabbyTestFixtures.suggestionRequest(
            prefixText: "We are meet",
            wordRange: SuggestionWordCountPreset.currentWord.range
        )
        XCTAssertEqual(SuggestionTextNormalizer.normalizeDetailed("ing tomorrow at noon", for: request).text, "ing")
    }
}
