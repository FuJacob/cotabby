import XCTest
@testable import Ghostype

/// Pins the pure rules behind selected-word synonyms: what counts as one word, which focus snapshots
/// may offer synonyms, how a model reply becomes clean choices in the original word's case, and which
/// keystrokes pick a choice.
final class SelectedWordSynonymsTests: XCTestCase {
    // MARK: - Single word

    func test_lettersApostrophesAndHyphensAreOneWord() {
        for word in ["happy", "Happy", "don't", "don’t", "well-known", "naïve", "über", "ok"] {
            XCTAssertTrue(SelectedWordSynonyms.isSingleWord(word), word)
        }
    }

    func test_phrasesNumbersCodeAndExtremeLengthsAreNotOneWord() {
        let rejected = [
            "", "a", "two words", "word ", " word", "word.", "abc123", "42", "snake_case", "--", "'-'",
            "e-mail@x", "line\nbreak", String(repeating: "a", count: 41)
        ]
        for text in rejected {
            XCTAssertFalse(SelectedWordSynonyms.isSingleWord(text), text)
        }
        XCTAssertTrue(SelectedWordSynonyms.isSingleWord(String(repeating: "a", count: 40)))
    }

    // MARK: - Trigger

    func test_selectedWordInASelectionBlockedFieldTriggers() {
        let snapshot = Self.snapshot(selectedText: "happy")
        XCTAssertEqual(SelectedWordSynonyms.selectedWord(in: snapshot), "happy")
    }

    func test_otherBlocksSecureFieldsAndBareCaretsDoNotTrigger() {
        XCTAssertNil(SelectedWordSynonyms.selectedWord(in: Self.snapshot(selectedText: "happy", capability: .blocked("Secure text input is active."))))
        XCTAssertNil(SelectedWordSynonyms.selectedWord(in: Self.snapshot(selectedText: "happy", capability: .unsupported("nope"))))
        XCTAssertNil(SelectedWordSynonyms.selectedWord(in: Self.snapshot(selectedText: "happy", isSecure: true)))
        XCTAssertNil(SelectedWordSynonyms.selectedWord(in: Self.snapshot(selectedText: "")))
        XCTAssertNil(SelectedWordSynonyms.selectedWord(in: Self.snapshot(selectedText: "very happy")))
    }

    // MARK: - Request

    func test_requestCarriesOnlyTheFewShotPromptNotTheFieldText() {
        let field = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "secret draft ", trailingText: " more")
        let request = SelectedWordSynonyms.request(for: "Brave", in: field)

        XCTAssertTrue(request.prompt.hasSuffix("Synonyms for brave:"))
        XCTAssertEqual(request.prefixText, request.prompt)
        XCTAssertEqual(request.context.precedingText, request.prompt)
        XCTAssertEqual(request.context.trailingText, "")
        XCTAssertFalse(request.prompt.contains("secret"))
        XCTAssertFalse(request.isMultiLineEnabled)
        XCTAssertNil(request.wordRange)
    }

    // MARK: - Parsing

    func test_parseKeepsCleanSingleWordsInOrder() {
        XCTAssertEqual(
            SelectedWordSynonyms.parse(" courageous, bold, daring, fearless.", original: "brave"),
            ["courageous", "bold", "daring", "fearless"]
        )
    }

    func test_parseDropsTheWordItselfDuplicatesMultiWordAndEmptyEntries() {
        XCTAssertEqual(
            SelectedWordSynonyms.parse("Brave, bold, , BOLD, full of courage, gutsy,daring", original: "brave"),
            ["bold", "gutsy", "daring"]
        )
    }

    func test_parseReadsOnlyTheFirstLine() {
        XCTAssertEqual(
            SelectedWordSynonyms.parse(" bold, daring\nSynonyms for calm: quiet, still", original: "brave"),
            ["bold", "daring"]
        )
    }

    func test_parseCapsAtNine() {
        let reply = (1...12).map { "word" + String(repeating: "x", count: $0) }.joined(separator: ", ")
        XCTAssertEqual(SelectedWordSynonyms.parse(reply, original: "brave").count, 9)
    }

    func test_parseOfEmptyOrJunkReplyIsEmpty() {
        XCTAssertEqual(SelectedWordSynonyms.parse("", original: "brave"), [])
        XCTAssertEqual(SelectedWordSynonyms.parse("1. 2. 3.", original: "brave"), [])
    }

    // MARK: - Case

    func test_choicesFollowTheOriginalWordsCase() {
        XCTAssertEqual(SelectedWordSynonyms.parse("Bold, DARING", original: "brave"), ["bold", "daring"])
        XCTAssertEqual(SelectedWordSynonyms.parse("bold, DARING", original: "Brave"), ["Bold", "Daring"])
        XCTAssertEqual(SelectedWordSynonyms.parse("bold, daring", original: "BRAVE"), ["BOLD", "DARING"])
        XCTAssertEqual(SelectedWordSynonyms.matchingCase(of: "I", "me"), "Me")
    }

    // MARK: - Keys and label

    func test_bareDigitsPickAndModifiedOrOtherKeysDoNot() {
        XCTAssertEqual(SelectedWordSynonyms.choiceIndex(characters: "1", modifiers: []), 0)
        XCTAssertEqual(SelectedWordSynonyms.choiceIndex(characters: "9", modifiers: []), 8)
        XCTAssertNil(SelectedWordSynonyms.choiceIndex(characters: "0", modifiers: []))
        XCTAssertNil(SelectedWordSynonyms.choiceIndex(characters: "a", modifiers: []))
        XCTAssertNil(SelectedWordSynonyms.choiceIndex(characters: "!", modifiers: [.shift]))
        XCTAssertNil(SelectedWordSynonyms.choiceIndex(characters: "1", modifiers: [.command]))
        XCTAssertNil(SelectedWordSynonyms.choiceIndex(characters: "1", modifiers: [.option]))
    }

    func test_listLabelNumbersEachChoice() {
        XCTAssertEqual(SelectedWordSynonyms.listLabel(["glad", "merry"]), "1 glad   2 merry")
    }

    // MARK: - Fixtures

    static func snapshot(
        selectedText: String,
        capability: FocusCapability = .blocked(FocusCapability.textSelectedReason),
        isSecure: Bool = false
    ) -> FocusSnapshot {
        let preceding = "I am "
        let base = CotabbyTestFixtures.focusedInputSnapshot(precedingText: preceding, isSecure: isSecure)
        let context = FocusedInputSnapshot(
            applicationName: base.applicationName,
            bundleIdentifier: base.bundleIdentifier,
            processIdentifier: base.processIdentifier,
            elementIdentifier: base.elementIdentifier,
            role: base.role,
            subrole: base.subrole,
            caretRect: base.caretRect,
            inputFrameRect: base.inputFrameRect,
            caretSource: base.caretSource,
            caretQuality: base.caretQuality,
            observedCharWidth: nil,
            precedingText: preceding,
            trailingText: " today",
            selection: NSRange(location: (preceding as NSString).length, length: (selectedText as NSString).length),
            selectedText: selectedText,
            isSecure: isSecure,
            focusChangeSequence: 1
        )
        return FocusSnapshot(applicationName: "TestApp", bundleIdentifier: "com.test.app", capability: capability, context: context)
    }
}
