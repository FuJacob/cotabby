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
}
