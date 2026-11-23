import Foundation
import XCTest
@testable import Cotabby

/// Pins how far Cotabby trusts an endpoint's response: redirects stay on the configured server,
/// SSE lines are split exactly as the format defines and capped, the whole stream has text and time
/// budgets, and partial updates are paced without ever withholding the first one.
final class OpenAICompatibleTransportPolicyTests: XCTestCase {
    // MARK: - Redirects

    func test_redirectPolicy_followsOnlyRedirectsThatStayOnTheSameServer() {
        let original = URL(string: "https://models.example.com/v1/chat/completions")
        let cases: [(destination: String, allowed: Bool)] = [
            ("https://models.example.com/v1/chat/completions/", true),
            ("https://MODELS.example.com:443/v2/chat/completions", true),
            ("https://collector.example.net/v1/chat/completions", false),
            ("http://models.example.com/v1/chat/completions", false),
            ("https://models.example.com:8443/v1/chat/completions", false),
            ("https://models.example.com.collector.example.net/v1", false)
        ]

        for testCase in cases {
            XCTAssertEqual(
                OpenAICompatibleRedirectPolicy.allowsRedirect(from: original, to: URL(string: testCase.destination)),
                testCase.allowed,
                testCase.destination
            )
        }
        XCTAssertFalse(OpenAICompatibleRedirectPolicy.allowsRedirect(from: nil, to: original))
        XCTAssertFalse(OpenAICompatibleRedirectPolicy.allowsRedirect(from: original, to: nil))
    }

    // MARK: - Limits

    func test_streamLimits_scaleTextWithTheRequestedTokenBudget() {
        XCTAssertEqual(OpenAICompatibleStreamLimits.forRequest(maxPredictionTokens: 8).maxTextCharacters, 4_096)
        let multiLine = OpenAICompatibleStreamLimits.forRequest(maxPredictionTokens: 120)
        XCTAssertEqual(multiLine.maxTextCharacters, 7_680)
        XCTAssertEqual(multiLine.maxLineBytes, 256 * 1_024)
        XCTAssertEqual(multiLine.maxResponseBytes, 4 * 1_024 * 1_024)
        XCTAssertEqual(multiLine.maxDuration, 180)
    }

    func test_budget_capsTextAndTotalDuration() throws {
        var budget = OpenAICompatibleStreamBudget(limits: OpenAICompatibleStreamLimits(
            maxLineBytes: 64,
            maxResponseBytes: 1_024,
            maxTextCharacters: 5,
            maxDuration: 10
        ))

        try budget.spend("abc")
        try budget.spend("de")
        XCTAssertEqual(budget.textCharacters, 5, "Exactly the cap is allowed")
        do {
            try budget.spend("f")
            XCTFail("Expected tooMuchText")
        } catch {
            XCTAssertEqual(error as? OpenAICompatibleStreamLimitError, .tooMuchText)
        }

        XCTAssertNoThrow(try budget.checkElapsed(10))
        XCTAssertThrowsError(try budget.checkElapsed(10.5)) { error in
            XCTAssertEqual(error as? OpenAICompatibleStreamLimitError, .tookTooLong)
        }
    }

    // MARK: - Line splitting

    func test_lineSplitter_endsLinesAtLFCRLFAndCR() throws {
        var splitter = OpenAICompatibleSSELineSplitter(maxLineBytes: 64, maxResponseBytes: 1_024)

        let lines = try feed("a\nb\r\nc\rd\r\n\ne", into: &splitter)
        XCTAssertEqual(lines, ["a", "b", "c", "d", ""])
        XCTAssertEqual(splitter.finish(), "e", "A body without a final line break still yields its last line")
        XCTAssertNil(splitter.finish())
    }

    func test_lineSplitter_keepsMultiByteCharactersIntact() throws {
        var splitter = OpenAICompatibleSSELineSplitter(maxLineBytes: 64, maxResponseBytes: 1_024)

        let lines = try feed("data: héllo 👋\n", into: &splitter)
        XCTAssertEqual(lines, ["data: héllo 👋"])
    }

    func test_lineSplitter_rejectsALineLongerThanTheCap() throws {
        var splitter = OpenAICompatibleSSELineSplitter(maxLineBytes: 4, maxResponseBytes: 1_024)
        let lines = try feed("abcd\n", into: &splitter)
        XCTAssertEqual(lines, ["abcd"], "Exactly the cap is allowed")

        do {
            _ = try feed("abcde", into: &splitter)
            XCTFail("Expected lineTooLong")
        } catch {
            XCTAssertEqual(error as? OpenAICompatibleStreamLimitError, .lineTooLong)
        }
    }

    func test_lineSplitter_capsTheWholeResponseIncludingIgnoredLines() {
        var splitter = OpenAICompatibleSSELineSplitter(maxLineBytes: 64, maxResponseBytes: 6)

        do {
            _ = try feed(":\n:\n:\n:\n", into: &splitter)
            XCTFail("Expected responseTooLarge")
        } catch {
            XCTAssertEqual(error as? OpenAICompatibleStreamLimitError, .responseTooLarge)
        }
    }

    // MARK: - Partial pacing

    func test_partialThrottle_emitsTheFirstUpdateThenAtMostOncePerInterval() {
        var throttle = OpenAICompatiblePartialThrottle(minimumInterval: 0.5)

        XCTAssertTrue(throttle.shouldEmit(at: 10))
        XCTAssertFalse(throttle.shouldEmit(at: 10.25))
        XCTAssertTrue(throttle.shouldEmit(at: 10.5))
        XCTAssertFalse(throttle.shouldEmit(at: 10.75))
        XCTAssertTrue(throttle.shouldEmit(at: 12))
    }

    func test_partialThrottle_zeroIntervalEmitsEveryUpdate() {
        var throttle = OpenAICompatiblePartialThrottle(minimumInterval: 0)

        var decisions: [Bool] = []
        for _ in 0..<4 {
            decisions.append(throttle.shouldEmit(at: 7))
        }
        XCTAssertEqual(decisions, [true, true, true, true])
    }

    // MARK: - Helpers

    private func feed(_ text: String, into splitter: inout OpenAICompatibleSSELineSplitter) throws -> [String] {
        var lines: [String] = []
        for byte in text.utf8 {
            if let line = try splitter.append(byte) {
                lines.append(line)
            }
        }
        return lines
    }
}
