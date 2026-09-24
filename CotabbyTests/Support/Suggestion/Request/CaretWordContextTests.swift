import XCTest
@testable import Cotabby

/// Boundaries come from typed characters, never elapsed time or dictionary membership.
final class CaretWordContextTests: XCTestCase {
    func testEveryPausedPrefixRemainsUncommitted() {
        for word in ["because", "schedule", "recommend", "Celsius", "don't"] {
            for count in 1...word.count {
                let text = "Please " + word.prefix(count)
                XCTAssertNil(CaretWordContext.committedWord(in: text), text)
                XCTAssertEqual(CaretWordContext.unfinishedWord(in: text), String(word.prefix(count)))
            }
        }
    }

    func testCommittedPunctuationIsPreservedOnAcceptance() {
        for delimiter in [" ", ",", "!", "? "] {
            XCTAssertEqual(CaretWordContext.committedWord(in: "a nmae" + delimiter)?.word, "nmae")
            XCTAssertEqual(TypoCorrectionReplacementPlanner.plan(
                precedingText: "a nmae" + delimiter, expectedTypo: "nmae", correctedWord: "name", requiresTrailingSpace: false
            )?.replacementText, "name" + delimiter)
        }
        XCTAssertNil(TypoCorrectionReplacementPlanner.plan(
            precedingText: "a nmae", expectedTypo: "nmae", correctedWord: "name", requiresTrailingSpace: false))
    }

    func testCodeAndUnspacedScriptsRemainOutsideLexicalPolicy() {
        for text in ["call user_name", "open example.com", "version v2", "今日は", "word  ",
                     "call(wor", "array[wor", "[wor", "{wor", "`wor", "\"user_name", "(example.com"] {
            XCTAssertNil(CaretWordContext.unfinishedWord(in: text))
            XCTAssertNil(CaretWordContext.committedWord(in: text))
        }
    }

    func testProseOpenersKeepTheWordInsideTheLexicalPolicy() {
        for opening in ["(", "\"", "'", "“", "‘", "«", "‹", "(“"] {
            XCTAssertEqual(CaretWordContext.unfinishedWord(in: "Try " + opening + "wor"), "wor")
            XCTAssertEqual(CaretWordContext.unfinishedWord(in: "Try " + opening + "don't"), "don't")
            XCTAssertNil(CaretWordContext.unfinishedWord(in: "Try " + opening))
        }
    }

    /// Recognizing prose for generation does not expand the strict replacement planner's range.
    func testOpeningPunctuationDoesNotBecomePartOfACorrection() {
        for opening in ["(", "\"", "“"] {
            XCTAssertNil(CaretWordContext.committedWord(in: "Try " + opening + "nmae "))
        }
    }
}
