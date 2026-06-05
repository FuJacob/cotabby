import XCTest
@testable import Cotabby

final class CurrentWordExtractorTests: XCTestCase {
    func test_extractsTrailingWordAtCaret() {
        let result = CurrentWordExtractor.extract(from: "hi my nmae")
        XCTAssertEqual(result?.word, "nmae")
        XCTAssertEqual(result?.characterCount, 4)
    }

    func test_returnsNilWhenCaretFollowsWhitespace() {
        // A trailing space means there is no "current word" the caret sits inside.
        XCTAssertNil(CurrentWordExtractor.extract(from: "hi my nmae "))
    }

    func test_returnsNilForEmptyText() {
        XCTAssertNil(CurrentWordExtractor.extract(from: ""))
    }

    func test_returnsNilForSingleCharacterWord() {
        // Single-letter tokens are too noisy to act on.
        XCTAssertNil(CurrentWordExtractor.extract(from: "a"))
        XCTAssertNil(CurrentWordExtractor.extract(from: "I am a"))
    }

    func test_rejectsAllCapsAcronyms() {
        XCTAssertNil(CurrentWordExtractor.extract(from: "ship via HTTP"))
        XCTAssertNil(CurrentWordExtractor.extract(from: "parse JSON"))
    }

    func test_rejectsTokensWithDigits() {
        XCTAssertNil(CurrentWordExtractor.extract(from: "build v2"))
        XCTAssertNil(CurrentWordExtractor.extract(from: "room 101a"))
    }

    func test_rejectsCodeLikeTokens() {
        XCTAssertNil(CurrentWordExtractor.extract(from: "open https://example.com"))
        XCTAssertNil(CurrentWordExtractor.extract(from: "call user_name"))
        XCTAssertNil(CurrentWordExtractor.extract(from: "ping @jacob"))
        XCTAssertNil(CurrentWordExtractor.extract(from: "the file.swift"))
    }

    func test_acceptsMixedCaseNaturalWord() {
        XCTAssertEqual(CurrentWordExtractor.extract(from: "fix teh")?.word, "teh")
        // Leading-capital natural words are fine; only ALL-caps tokens are rejected.
        XCTAssertEqual(CurrentWordExtractor.extract(from: "say Teh")?.word, "Teh")
    }

    func test_characterCountIsGraphemeCount() {
        // Accented letters that compose to a single grapheme count as one deletable character.
        let result = CurrentWordExtractor.extract(from: "a cafz")
        XCTAssertEqual(result?.word, "cafz")
        XCTAssertEqual(result?.characterCount, 4)
    }

    // MARK: - Tolerant trailing-space extraction

    func test_trailingWord_noSpaceMatchesStrictExtraction() {
        let extracted = CurrentWordExtractor.extractTrailingWord(from: "hi my nmae")
        XCTAssertEqual(extracted?.result.word, "nmae")
        XCTAssertEqual(extracted?.trailingSpaceCount, 0)
    }

    func test_trailingWord_toleratesOneTrailingSpace() {
        let extracted = CurrentWordExtractor.extractTrailingWord(from: "hi my nmae ")
        XCTAssertEqual(extracted?.result.word, "nmae")
        XCTAssertEqual(extracted?.trailingSpaceCount, 1)
    }

    func test_trailingWord_rejectsTwoTrailingSpaces() {
        XCTAssertNil(CurrentWordExtractor.extractTrailingWord(from: "hi my nmae  "))
    }

    func test_trailingWord_rejectsTrailingTabOrNewline() {
        XCTAssertNil(CurrentWordExtractor.extractTrailingWord(from: "hi my nmae\t"))
        XCTAssertNil(CurrentWordExtractor.extractTrailingWord(from: "hi my nmae\n"))
    }

    func test_trailingWord_rejectsImplausibleWordEvenWithSpace() {
        XCTAssertNil(CurrentWordExtractor.extractTrailingWord(from: "open https://example.com "))
    }
}
