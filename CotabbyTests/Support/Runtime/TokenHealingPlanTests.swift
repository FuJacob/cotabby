import XCTest
@testable import Cotabby

/// Checks editor-byte and work-budget invariants independently of any model vocabulary.
final class TokenHealingPlanTests: XCTestCase {
    private func plan(_ prompt: String, _ pieces: [String], singleLine: Bool = false) -> TokenHealingPlan {
        let bytes = pieces.map { Array($0.utf8) }
        return TokenHealingPlan(prompt: prompt, tokens: pieces.indices.map { Int32($0) }, singleLine: singleLine) {
            bytes[Int($0)]
        }
    }

    func testPartialWordSpanningTokensCanChooseAWholeWordToken() {
        let value = plan("apple intell", ["", "apple", " int", "ell"])
        XCTAssertEqual(value.promptTokens, [0, 1])
        XCTAssertEqual(String(bytes: value.replayBytes, encoding: .utf8), " intell")
        var buffer = TokenHealingBuffer(replayedPrefix: value.replayBytes)
        XCTAssertEqual(buffer.append(tokenBytes: Array(" intelligence".utf8)), "igence")
    }

    func testAlreadyCompletedWordCanReplayExactlyBeforeAddingSpace() {
        let value = plan("apple intelligence", ["", "apple", " int", "elligence"])
        XCTAssertEqual(value.promptTokens, [0, 1])
        var buffer = TokenHealingBuffer(replayedPrefix: value.replayBytes)
        XCTAssertNil(buffer.append(tokenBytes: Array(" intelligence".utf8)))
        XCTAssertEqual(buffer.append(tokenBytes: Array(" is".utf8)), " is")
    }

    func testTrailingSpaceDoesNotReconsiderThePreviousWord() {
        let value = plan("apple ", ["", "apple", " "])
        XCTAssertEqual(value.promptTokens, [0, 1])
        XCTAssertEqual(value.replayBytes, Array(" ".utf8))
    }

    func testUnicodeScalarSplitAcrossTokensReplaysExactBytes() {
        let pieces: [[UInt8]] = [[], Array("Try".utf8), [0x20, 0xC3], [0xA9]]
        let value = TokenHealingPlan(prompt: "Try é", tokens: [0, 1, 2, 3], singleLine: false) { pieces[Int($0)] }
        XCTAssertEqual(value.promptTokens, [0, 1])
        XCTAssertEqual(value.replayBytes, Array(" é".utf8))
        var buffer = TokenHealingBuffer(replayedPrefix: value.replayBytes)
        XCTAssertEqual(buffer.append(tokenBytes: Array(" éclair".utf8)), "clair")
    }

    func testLongIdentifierRetainsBoundedLastTokenFallback() {
        let value = plan("a extraordinarilylongidentifier", ["", "a", " extraordinarilylong", "identifier"])
        XCTAssertEqual(value.promptTokens, [0, 1, 2])
        XCTAssertEqual(value.replayBytes, Array("identifier".utf8))
        XCTAssertLessThanOrEqual(value.replayBytes.count, TokenHealingBuffer.maximumReplayTokens)
    }

    func testTokenOvershootingBudgetDoesNotRemoveThePreviousWord() {
        let value = plan("extraordinarilylong intell", ["", "extraordinarilylong int", "ell"])
        XCTAssertEqual(value.promptTokens, [0, 1])
        XCTAssertEqual(value.replayBytes, Array("ell".utf8))
    }

    func testSingleLineReplayCannotCrossANewlineInsideAToken() {
        let value = plan("title\nintell", ["", "title", "\nint", "ell"], singleLine: true)
        XCTAssertEqual(value.promptTokens, [0, 1, 2])
        XCTAssertEqual(value.replayBytes, Array("ell".utf8))
    }

    func testNewlineRemainsConditioningWhenTokenBoundaryAllowsIt() {
        let value = plan("title\nintell", ["", "title", "\n", "int", "ell"], singleLine: true)
        XCTAssertEqual(value.promptTokens, [0, 1, 2])
        XCTAssertEqual(value.replayBytes, Array("intell".utf8))
    }

    func testTokenizerNormalizationCannotRewriteTheEditorsBytes() {
        let value = plan("Try é", ["", "Try", " e\u{301}"])
        XCTAssertEqual(value.promptTokens, [0, 1, 2])
        XCTAssertTrue(value.replayBytes.isEmpty)
    }

    func testAtLeastOneConditioningTokenSurvivesWithoutBOS() {
        let value = plan("intell", ["int", "ell"])
        XCTAssertEqual(value.promptTokens, [0])
        XCTAssertEqual(value.replayBytes, Array("ell".utf8))
        let single = plan("int", ["int"])
        XCTAssertEqual(single.promptTokens, [0])
        XCTAssertTrue(single.replayBytes.isEmpty)
    }
}
