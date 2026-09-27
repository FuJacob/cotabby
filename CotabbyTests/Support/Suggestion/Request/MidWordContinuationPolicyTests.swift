import XCTest
@testable import Cotabby

/// Pure-function tests for the mid-word continuation trigger.
final class MidWordContinuationPolicyTests: XCTestCase {

    func test_caretInsideWord_forcesContinuation() {
        XCTAssertTrue(
            MidWordContinuationPolicy.shouldForceContinuation(precedingText: "I am wri", trailingText: "ting")
        )
    }

    func test_caretAtWordEnd_doesNotForce() {
        // Nothing after the caret: a normal word boundary, where next-word predictions belong.
        XCTAssertFalse(
            MidWordContinuationPolicy.shouldForceContinuation(precedingText: "The quick brown fox", trailingText: "")
        )
    }

    func test_spaceBeforeCaret_doesNotForce() {
        XCTAssertFalse(
            MidWordContinuationPolicy.shouldForceContinuation(precedingText: "hello ", trailingText: "world")
        )
    }

    func test_punctuationAfterCaret_doesNotForce() {
        XCTAssertFalse(
            MidWordContinuationPolicy.shouldForceContinuation(precedingText: "done", trailingText: ". Next")
        )
    }

    func test_wordCharacterBoundaries() {
        let cases: [(name: String, preceding: String, trailing: String, expected: Bool)] = [
            // Digits count as word characters, so identifiers and numbers heal like words.
            ("digits on both sides", "build 12", "34", true),
            ("letter then digit", "v", "2", true),
            ("non-ASCII letters", "caf", "é au lait", true),
            ("CJK inside a run", "今日", "は", true),
            ("empty preceding text", "", "word", false),
            // A connector is not a word character: the trigger stays narrow at `don|'t`.
            ("apostrophe after caret", "don", "'t", false),
            ("newline after caret", "word", "\nnext", false)
        ]
        for testCase in cases {
            XCTAssertEqual(
                MidWordContinuationPolicy.shouldForceContinuation(
                    precedingText: testCase.preceding,
                    trailingText: testCase.trailing
                ),
                testCase.expected,
                testCase.name
            )
        }
    }
}
