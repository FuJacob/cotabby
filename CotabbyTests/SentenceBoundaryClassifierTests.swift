import XCTest
@testable import Cotabby

/// Pure-function tests for period disambiguation used by phrase-level acceptance.
final class SentenceBoundaryClassifierTests: XCTestCase {

    private func lastPeriodIndex(in text: String) -> String.Index {
        guard let index = text.lastIndex(of: ".") else {
            XCTFail("test string must contain a period: \(text)")
            return text.startIndex
        }
        return index
    }

    func test_endOfRealSentence_isTerminal() {
        let text = "I went home."
        XCTAssertTrue(SentenceBoundaryClassifier.isTerminalPeriod(in: text, at: lastPeriodIndex(in: text)))
    }

    func test_wordEndingSentence_isTerminal() {
        let text = "I have a cat."
        XCTAssertTrue(SentenceBoundaryClassifier.isTerminalPeriod(in: text, at: lastPeriodIndex(in: text)))
    }

    func test_decimalNumber_isNotTerminal() {
        let text = "pi is 3.14"
        XCTAssertFalse(SentenceBoundaryClassifier.isTerminalPeriod(in: text, at: lastPeriodIndex(in: text)))
    }

    func test_listNumber_isNotTerminal() {
        let text = "item 1."
        XCTAssertFalse(SentenceBoundaryClassifier.isTerminalPeriod(in: text, at: lastPeriodIndex(in: text)))
    }

    func test_singleLetterInitial_isNotTerminal() {
        let text = "I visited the U.S."
        XCTAssertFalse(SentenceBoundaryClassifier.isTerminalPeriod(in: text, at: lastPeriodIndex(in: text)))
    }

    func test_knownAbbreviation_isNotTerminal() {
        let text = "tabs and so on etc."
        XCTAssertFalse(SentenceBoundaryClassifier.isTerminalPeriod(in: text, at: lastPeriodIndex(in: text)))
    }

    func test_leadingPeriodWithNothingBefore_isTerminal() {
        // A period at the very start has no preceding word to qualify it, so it keeps the old
        // unconditional behavior and counts as terminal.
        let text = "."
        XCTAssertTrue(SentenceBoundaryClassifier.isTerminalPeriod(in: text, at: text.startIndex))
        XCTAssertTrue(SentenceBoundaryClassifier.endsSentence("."))
    }

    // MARK: - endsSentence

    func test_endsSentence_trueForTerminalPeriod() {
        XCTAssertTrue(SentenceBoundaryClassifier.endsSentence("Hello world."))
    }

    func test_endsSentence_falseWithoutTerminator() {
        XCTAssertFalse(SentenceBoundaryClassifier.endsSentence("Hello world"))
    }

    func test_endsSentence_trueForExclamationAndQuestion() {
        XCTAssertTrue(SentenceBoundaryClassifier.endsSentence("Yes!"))
        XCTAssertTrue(SentenceBoundaryClassifier.endsSentence("Really?"))
    }

    func test_endsSentence_ignoresTrailingWhitespace() {
        XCTAssertTrue(SentenceBoundaryClassifier.endsSentence("Done.   "))
    }

    func test_endsSentence_walksPastClosingPunctuation() {
        XCTAssertTrue(SentenceBoundaryClassifier.endsSentence("He said \"stop.\""))
        XCTAssertTrue(SentenceBoundaryClassifier.endsSentence("(done!)"))
    }

    func test_endsSentence_falseForNonTerminalPeriods() {
        XCTAssertFalse(SentenceBoundaryClassifier.endsSentence("It is version 1."))
        XCTAssertFalse(SentenceBoundaryClassifier.endsSentence("for example, e.g."))
        XCTAssertFalse(SentenceBoundaryClassifier.endsSentence("from the U.S."))
        XCTAssertFalse(SentenceBoundaryClassifier.endsSentence("Hello Mr."))
    }

    func test_endsSentence_falseForEmptyString() {
        XCTAssertFalse(SentenceBoundaryClassifier.endsSentence(""))
    }

    /// CJK terminators are unambiguous sentence ends. Without these the decode stop policy never
    /// fires for Japanese/Chinese text and generation always runs to the token budget, which is why
    /// CJK suggestions came out so long.
    func test_endsSentence_trueForCJKTerminators() {
        XCTAssertTrue(SentenceBoundaryClassifier.endsSentence("資料を読む。"))
        XCTAssertTrue(SentenceBoundaryClassifier.endsSentence("すごい！"))
        XCTAssertTrue(SentenceBoundaryClassifier.endsSentence("いいですか？"))
    }

    func test_endsSentence_walksPastCJKClosingPunctuation() {
        XCTAssertTrue(SentenceBoundaryClassifier.endsSentence("終わり。」"))
    }

    /// Halfwidth kana punctuation (legacy SJIS contexts) terminates like its fullwidth counterparts,
    /// including the walk past a halfwidth corner bracket.
    func test_endsSentence_trueForHalfwidthTerminatorAndCloser() {
        XCTAssertTrue(SentenceBoundaryClassifier.endsSentence("終わり｡"))
        XCTAssertTrue(SentenceBoundaryClassifier.endsSentence("終わり｡｣"))
    }

    /// The ideographic comma is a clause boundary, not a sentence end: generation should keep going
    /// past `、` and only stop at a real terminator.
    func test_endsSentence_falseForIdeographicComma() {
        XCTAssertFalse(SentenceBoundaryClassifier.endsSentence("資料を読み、"))
    }
}
