@testable import Cotabby
import XCTest

final class TypingHistoryPhrasePredictorTests: XCTestCase {
    private let limits = TypingHistoryPhrasePredictor.Limits(maxWords: 12, allowsNewlines: false)

    private func record(_ text: String) -> TypingHistoryRecord {
        TypingHistoryRecord(
            id: UUID(), bundleIdentifier: "com.apple.mail", domain: nil,
            createdAt: Date(), updatedAt: Date(), text: text, source: .imported
        )
    }

    private func predictor(_ texts: [String]) -> TypingHistoryPhrasePredictor {
        TypingHistoryPhrasePredictor(records: texts.map(record))
    }

    func test_repeatedPhraseIsCompletedAfterAWordBoundary() {
        let history = Array(repeating: "Thanks again, please let me know if you have any questions.", count: 4)

        XCTAssertEqual(
            predictor(history).continuation(after: "Sure, please let me know ", limits: limits),
            "if you have any questions."
        )
    }

    func test_partialWordIsFinishedWithOnlyTheUntypedLetters() {
        let history = Array(repeating: "Thanks again, please let me know if you have any questions.", count: 4)

        XCTAssertEqual(
            predictor(history).continuation(after: "Sure, please let me know if you ha", limits: limits),
            "ve any questions."
        )
    }

    func test_fullyTypedWordWithoutSpaceGetsALeadingSpace() {
        let history = Array(repeating: "Thanks again, please let me know if you have any questions.", count: 4)

        XCTAssertEqual(
            predictor(history).continuation(after: "Sure, please let me know if", limits: limits),
            " you have any questions."
        )
    }

    func test_ambiguousContinuationIsNotOffered() {
        let history = [
            "please let me know if it works",
            "please let me know when it ships",
            "please let me know what you think",
            "please let me know how it goes"
        ]

        XCTAssertNil(predictor(history).continuation(after: "please let me know ", limits: limits))
    }

    func test_tooFewOccurrencesAreNotOffered() {
        let history = Array(repeating: "please let me know if you have any questions.", count: 2)

        XCTAssertNil(predictor(history).continuation(after: "please let me know ", limits: limits))
    }

    func test_singleWordShortcutNeedsStrongerEvidence() {
        let three = Array(repeating: "Thanks for the update.\nBest regards, Senad\nImperum", count: 3)
        let six = Array(repeating: "Thanks for the update.\nBest regards, Senad\nImperum", count: 6)

        XCTAssertNil(predictor(three).continuation(after: "Thanks!\nBest regards, ", limits: limits))
        XCTAssertEqual(predictor(six).continuation(after: "Thanks!\nBest regards, ", limits: limits), "Senad")
    }

    func test_newlineContinuesOnlyWhenMultiLineIsAllowed() {
        let history = Array(repeating: "Thanks for your time.\nKind regards,\nSenad Aruc\nImperum B.V.", count: 6)
        let multiLine = TypingHistoryPhrasePredictor.Limits(maxWords: 12, allowsNewlines: true)

        XCTAssertNil(predictor(history).continuation(after: "Thanks for your time.\nKind regards,", limits: limits))
        XCTAssertEqual(
            predictor(history).continuation(after: "Thanks for your time.\nKind regards,", limits: multiLine),
            "\nSenad Aruc\nImperum B.V."
        )
    }

    func test_outputUsesTheUsersSpellingAndRespectsTheWordLimit() {
        let history = Array(repeating: "we will start the imperum POC with the SOC team next Monday morning", count: 4)
        let twoWords = TypingHistoryPhrasePredictor.Limits(maxWords: 2, allowsNewlines: false)

        XCTAssertEqual(predictor(history).continuation(after: "Then we will start the ", limits: twoWords), "imperum POC")
    }

    func test_twoWordFallbackAnswersWhenTheThirdWordIsNew() {
        // "Kind regards," follows many different sentences, so the three-word context before it is
        // rarely the same; the two-word fallback still knows what comes next.
        let history = (0..<6).map { "Topic number \($0) is done.\nKind regards,\nSenad" }
        let multiLine = TypingHistoryPhrasePredictor.Limits(maxWords: 12, allowsNewlines: true)

        XCTAssertEqual(
            predictor(history).continuation(after: "Something never seen before.\nKind regards,", limits: multiLine),
            "\nSenad"
        )
    }

    func test_onlyTextTypedBeforeTheCaretIsLearned() {
        // The quoted thread after the caret is someone else's writing; their name must not become
        // the user's sign-off.
        let records = (0..<6).map { _ -> TypingHistoryRecord in
            let typed = "Thanks for the update.\nBest regards, Senad"
            let quoted = "\n\nOn Monday Luuk wrote:\nThanks for the update.\nBest regards, Luuk"
            var record = record(typed + quoted)
            record.typedLength = typed.count
            return record
        }

        XCTAssertEqual(
            TypingHistoryPhrasePredictor(records: records).continuation(after: "Done.\nBest regards, ", limits: limits),
            "Senad"
        )
    }

    func test_unknownContextReturnsNil() {
        XCTAssertNil(predictor(["hello there general kenobi"]).continuation(after: "completely new words ", limits: limits))
        XCTAssertNil(predictor([]).continuation(after: "", limits: limits))
    }
}
