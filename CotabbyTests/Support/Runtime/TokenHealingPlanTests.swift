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

    func testUnhealedPlanKeepsTheExactPromptSoMidWordMaskingApplies() {
        let tokens: [Int32] = [0, 1, 2, 3]
        let value = TokenHealingPlan.unhealed(tokens: tokens)
        XCTAssertEqual(value.promptTokens, tokens)
        XCTAssertTrue(value.replayBytes.isEmpty, "An empty replay leaves the native whitespace mask in force")
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

    func testLastTokenHealingGuards() {
        // Each row isolates one guard on removing the final prompt token; the word-extension pass
        // only runs after a successful removal whose prompt ends in a letter or digit.
        let cases: [(name: String, prompt: String, pieces: [String], singleLine: Bool, kept: [Int32], replay: String)] = [
            // 18 bytes exceeds `maximumHealedTokenBytes` (16): nothing is removed.
            ("oversized token", "x abcdefghijklmnopq", ["", "x", " abcdefghijklmnopq"], false, [0, 1, 2], ""),
            // An empty (special) piece cannot be replayed byte-for-byte.
            ("empty piece", "ab", ["", "ab", ""], false, [0, 1, 2], ""),
            // Single-line fields never replay a newline; multi-line fields may.
            ("single-line newline", "a\n", ["", "a", "\n"], true, [0, 1, 2], ""),
            ("single-line carriage return", "a\r", ["", "a", "\r"], true, [0, 1, 2], ""),
            ("multi-line newline", "a\n", ["", "a", "\n"], false, [0, 1], "\n"),
            // Punctuation at the caret heals only that token, not the word before it.
            ("trailing punctuation", "hello,", ["", "hello", ","], false, [0, 1], ","),
            // Exactly at the byte limit still heals.
            ("token at limit", "x abcdefghijklmno", ["", "x", " abcdefghijklmno"], false, [0, 1], " abcdefghijklmno")
        ]
        for testCase in cases {
            let value = plan(testCase.prompt, testCase.pieces, singleLine: testCase.singleLine)
            XCTAssertEqual(value.promptTokens, testCase.kept, testCase.name)
            XCTAssertEqual(value.replayBytes, Array(testCase.replay.utf8), testCase.name)
        }
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
