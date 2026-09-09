import XCTest
@testable import Cotabby

final class WordBoundaryAnchorPolicyTests: XCTestCase {
    func testPartialWordAtTheCaretIsTheAnchor() {
        XCTAssertEqual(WordBoundaryAnchorPolicy.anchor(precedingText: "Thanks so much, I really apprec", trailingText: ""), "apprec")
        XCTAssertEqual(WordBoundaryAnchorPolicy.anchor(precedingText: "Unfortun", trailingText: ""), "Unfortun")
        XCTAssertEqual(WordBoundaryAnchorPolicy.anchor(precedingText: "I'm avail", trailingText: "\n"), "avail")
    }

    func testWordBoundariesDigitsPunctuationAndInsideTokensGiveNoAnchor() {
        XCTAssertNil(WordBoundaryAnchorPolicy.anchor(precedingText: "Thanks so much, I really ", trailingText: ""))
        XCTAssertNil(WordBoundaryAnchorPolicy.anchor(precedingText: "Meeting at 3", trailingText: ""))
        XCTAssertNil(WordBoundaryAnchorPolicy.anchor(precedingText: "don'", trailingText: ""), "an apostrophe is not a word boundary")
        XCTAssertNil(WordBoundaryAnchorPolicy.anchor(precedingText: "e-mai", trailingText: ""), "a hyphenated run stays with the model")
        XCTAssertEqual(WordBoundaryAnchorPolicy.anchor(precedingText: "a", trailingText: ""), "a", "one letter is a partial word")
        XCTAssertNil(WordBoundaryAnchorPolicy.anchor(precedingText: "head", trailingText: "phones"), "inside a token nothing is generated")
    }

    func testRequiredCompletionPrefixRestoresTheBoundaryWhitespace() {
        let policy = WordBoundaryAnchorPolicy.self
        XCTAssertEqual(policy.requiredCompletionPrefix(precedingText: "over the draft yest", anchor: "yest"), " yest")
        XCTAssertEqual(policy.requiredCompletionPrefix(precedingText: "Hi Sarah,\nTh", anchor: "Th"), "\nTh")
        XCTAssertEqual(policy.requiredCompletionPrefix(precedingText: "Th", anchor: "Th"), "Th", "no boundary before the first word")
    }

    func testPromptPrefixDropsTheAnchor() {
        XCTAssertEqual(WordBoundaryAnchorPolicy.promptPrefix("I really apprec", removing: "apprec"), "I really ")
        XCTAssertEqual(WordBoundaryAnchorPolicy.promptPrefix("unrelated", removing: "apprec"), "unrelated")
    }

    func testRemainderRequiresTheModelToCompleteTheTypedWord() {
        XCTAssertEqual(WordBoundaryAnchorPolicy.remainder(of: " appreciate it!", anchor: "apprec"), "iate it!")
        XCTAssertEqual(WordBoundaryAnchorPolicy.remainder(of: "Unfortunately, I", anchor: "Unfortun"), "ately, I")
        XCTAssertEqual(WordBoundaryAnchorPolicy.remainder(of: " unfortunately", anchor: "Unfortun"), "ately", "case differences belong to the user's typed part")
        XCTAssertNil(WordBoundaryAnchorPolicy.remainder(of: " approve it", anchor: "apprec"))
        XCTAssertNil(WordBoundaryAnchorPolicy.remainder(of: " app", anchor: "apprec"))
    }
}
