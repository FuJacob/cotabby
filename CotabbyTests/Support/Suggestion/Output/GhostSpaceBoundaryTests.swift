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
        XCTAssertEqual(adjusted("llet points", after: "add the bu", partialWord: true), "llet points")
    }

    /// Measured 2026-09-10 in Claude's composer: the user had typed the whole word, the model
    /// returned " that the timeline", and a rule that read every anchored remainder as the rest of
    /// the word stripped the space, gluing "thatthe timeline" 52 times in fifteen minutes.
    func testAnAnchoredWordTheModelEndedKeepsItsSpace() {
        XCTAssertEqual(adjusted(" the timeline", after: "I was thinking that", partialWord: true), " the timeline")
        XCTAssertEqual(adjusted(" on Friday", after: "at 12 PM", partialWord: true), " on Friday")
        XCTAssertEqual(adjusted(" section at", after: "add the budget", partialWord: true), " section at")
        XCTAssertEqual(
            adjusted(" the timeline", after: "I was thinking that ", partialWord: true), "the timeline",
            "a space typed meanwhile is the boundary"
        )
        XCTAssertEqual(adjusted(" , and", after: "I was thinking that", partialWord: true), ", and")
    }

    // MARK: - A base model's own spacing

    private func exact(_ completion: String, after preceding: String, request: String? = nil) -> String {
        GhostSpaceBoundary.adjusted(
            completion, precedingText: preceding, requestPrecedingText: request ?? preceding, continuesPartialWord: false
        )
    }

    /// Measured 2026-09-10 in Claude's composer: "1 50K", "10 0%" and "It' s" shown over
    /// completions the model had written joined.
    func testAJoinedContinuationStaysJoined() {
        XCTAssertEqual(exact("50K was too high", after: "I was thinking that 1"), "50K was too high")
        XCTAssertEqual(exact("00% accuracy", after: "exactly, with 1"), "00% accuracy")
        XCTAssertEqual(exact("0% consistency", after: "with 10"), "0% consistency")
        XCTAssertEqual(exact("s not always", after: "SPACE HANDLING. It'"), "s not always")
        XCTAssertEqual(exact("s", after: "on Friday"), "s")
    }

    func testTheModelsOwnSpaceStartsANewWord() {
        XCTAssertEqual(exact(" on Friday", after: "at 12 PM"), " on Friday")
        XCTAssertEqual(exact(" months is too long.", after: "I was thinking that 12"), " months is too long.")
        XCTAssertEqual(exact(" (see page 2)", after: "the report"), " (see page 2)")
        XCTAssertEqual(exact("  two spaces", after: "word"), " two spaces", "repeated spaces collapse to one")
    }

    func testASpaceTypedDuringGenerationIsNotDoubled() {
        XCTAssertEqual(exact(" on Friday", after: "at 12 PM ", request: "at 12 PM"), "on Friday")
        XCTAssertEqual(exact(" on Friday", after: "at 12 PM\u{00A0}", request: "at 12 PM"), "on Friday")
    }

    /// The normalizer drops the model's space after a request text that already ended with one; if
    /// the user deleted that space before the ghost appeared, the new word needs it back.
    func testASpaceDeletedAfterTheRequestIsRestored() {
        XCTAssertEqual(exact("on Friday", after: "at 12 PM", request: "at 12 PM "), " on Friday")
        XCTAssertEqual(exact("on Friday", after: "at 12 PM ", request: "at 12 PM "), "on Friday")
    }

    func testExactSpacingKeepsTheTypographyRules() {
        XCTAssertEqual(exact(" world", after: "Hello\n"), "world")
        XCTAssertEqual(exact(" , regards", after: "Best"), ", regards")
        XCTAssertEqual(exact(" 1.", after: "Make it 1:"), "1.")
        XCTAssertEqual(exact(" hello", after: "she said \""), "hello")
        XCTAssertEqual(exact(" draft", after: "the ("), "draft")
        XCTAssertEqual(exact("Hello", after: ""), "Hello")
        XCTAssertEqual(exact(" Hello", after: ""), "Hello")
        XCTAssertEqual(exact(" \nNext", after: "done"), "\nNext", "a completion opening with a line break takes no space")
    }

    /// Measured 2026-09-10 in Chrome's contenteditable: ". I'm going to bed now." written for
    /// "Friday" arrived after the user typed the space and showed as "Friday . I'm".
    func testPunctuationForAWordTheUserHasEndedIsStale() {
        XCTAssertTrue(GhostSpaceBoundary.isStaleAfterTypedSpace(". I'm going", precedingText: "See you on Friday "))
        XCTAssertTrue(GhostSpaceBoundary.isStaleAfterTypedSpace(", and then", precedingText: "Best "))
        XCTAssertFalse(GhostSpaceBoundary.isStaleAfterTypedSpace(". I'm going", precedingText: "See you on Friday"))
        XCTAssertFalse(GhostSpaceBoundary.isStaleAfterTypedSpace("I'm going", precedingText: "Friday. "))
        XCTAssertFalse(GhostSpaceBoundary.isStaleAfterTypedSpace("\"hello\"", precedingText: "she said "))
        XCTAssertFalse(GhostSpaceBoundary.isStaleAfterTypedSpace("(see below)", precedingText: "the report "))
    }

    // MARK: - Engines that do not vouch for their spacing

    func testDigitsAndContractionsStayJoinedWhateverTheEngine() {
        XCTAssertEqual(adjusted("50K", after: "that 1"), "50K")
        XCTAssertEqual(adjusted("s not always", after: "It'"), "s not always")
        XCTAssertEqual(adjusted("t know", after: "I don\u{2019}"), "t know")
        XCTAssertEqual(adjusted("and left", after: "she said 'hello'"), " and left", "a quote the word opened is closing")
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
