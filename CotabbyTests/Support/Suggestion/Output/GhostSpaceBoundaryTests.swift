import XCTest
@testable import Cotabby

/// Each case is one of the space symptoms reported from real use, stated as the text in the field
/// and what the model returned.
final class GhostSpaceBoundaryTests: XCTestCase {
    private func adjusted(_ completion: String, after preceding: String, partialWord: Bool = false) -> String {
        GhostSpaceBoundary.adjusted(completion, precedingText: preceding, continuesPartialWord: partialWord)
    }

    // MARK: - The space arrived while the model was generating

    func testCompletionKeepsOneSpaceWhenTheFieldHasNone() {
        XCTAssertEqual(adjusted(" world", after: "Hello"), " world")
        XCTAssertEqual(adjusted("world", after: "Hello"), " world", "a model that omitted the space must not glue")
    }

    func testCompletionDropsItsSpaceWhenTheFieldAlreadyEndsWithOne() {
        XCTAssertEqual(adjusted(" world", after: "Hello "), "world")
        XCTAssertEqual(adjusted("world", after: "Hello "), "world")
    }

    func testRepeatedSpacesInTheCompletionCollapseToTheOneThatBelongs() {
        XCTAssertEqual(adjusted("   world", after: "Hello"), " world")
        XCTAssertEqual(adjusted("   world", after: "Hello "), "world")
    }

    func testNonBreakingSpaceCountsAsTheBoundaryOnBothSides() {
        XCTAssertEqual(adjusted("\u{00A0}world", after: "Hello"), " world")
        XCTAssertEqual(adjusted("world", after: "Hello\u{00A0}"), "world")
    }

    // MARK: - Shapes that must never take a space

    func testACompletionFinishingTheUsersWordNeverTakesASpace() {
        XCTAssertEqual(adjusted("iate it", after: "I really apprec", partialWord: true), "iate it")
        XCTAssertEqual(adjusted(" iate it", after: "I really apprec", partialWord: true), "iate it")
    }

    func testPunctuationBindsToThePrecedingWord() {
        XCTAssertEqual(adjusted(", regards", after: "Best"), ", regards")
        XCTAssertEqual(adjusted(".", after: "tonight"), ".")
        XCTAssertEqual(adjusted("'s report", after: "the team"), "'s report")
    }

    func testNoSpaceAfterAnOpeningBracketOrJoiner() {
        XCTAssertEqual(adjusted("draft", after: "the (" ), "draft")
        XCTAssertEqual(adjusted("mail", after: "e-"), "mail")
    }

    func testNoSpaceAfterALineBreak() {
        XCTAssertEqual(adjusted("Best regards", after: "See you then.\n"), "Best regards")
    }

    func testEmptyInputsAreLeftAlone() {
        XCTAssertEqual(adjusted("", after: "Hello"), "")
        XCTAssertEqual(adjusted("world", after: ""), "world")
    }

    /// A completion after punctuation starts a new sentence, so it does take a space: this is the
    /// "visible.The" glue seen in real use.
    func testCompletionAfterASentenceEndTakesASpace() {
        XCTAssertEqual(adjusted("The next step", after: "Most text is visible."), " The next step")
        XCTAssertEqual(adjusted("and then", after: "the draft,"), " and then")
    }

    /// Typed live (2026-09-10): "Make it 1:" continued by "1." showed as "1: 1". A colon between
    /// digits is a ratio or a time; a colon after a word still introduces a clause.
    func testDigitsStayJoinedAcrossAColon() {
        XCTAssertEqual(adjusted("1.", after: "Make it 1:"), "1.")
        XCTAssertEqual(adjusted("30 sharp", after: "at 10:"), "30 sharp")
        XCTAssertEqual(adjusted("the", after: "Note:"), " the")
    }

    /// An unpaired straight quote is opening the quotation, so the quoted word follows it directly;
    /// after the closing quote of a pair the next word is a new one.
    func testAnOpeningQuoteTakesNoSpaceAndAClosingQuoteDoes() {
        XCTAssertEqual(adjusted("hello", after: "she said \""), "hello")
        XCTAssertEqual(adjusted("and left", after: "she said \"hello\""), " and left")
    }
}
