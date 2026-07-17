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
}
