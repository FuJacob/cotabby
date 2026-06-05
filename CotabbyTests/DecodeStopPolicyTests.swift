import XCTest
@testable import Cotabby

/// Tests for the decode-time early-stop decision. These lock in that generation stops at a genuine
/// sentence boundary, stays running through abbreviations / decimals / initialisms, and respects the
/// minimum-token guard that prevents degenerate instant stops.
final class DecodeStopPolicyTests: XCTestCase {
    func testBelowMinimumTokensDoesNotStop() {
        // Even a complete sentence should not stop before the minimum token count.
        XCTAssertFalse(DecodeStopPolicy.shouldStop(accumulated: "Hello there.", tokensGenerated: 1))
    }

    func testStopsAtSentenceEnd() {
        XCTAssertTrue(DecodeStopPolicy.shouldStop(accumulated: "Hello there.", tokensGenerated: 3))
    }

    func testStopsOnQuestionMark() {
        XCTAssertTrue(DecodeStopPolicy.shouldStop(accumulated: "Are you sure?", tokensGenerated: 3))
    }

    func testStopsOnExclamation() {
        XCTAssertTrue(DecodeStopPolicy.shouldStop(accumulated: "That works!", tokensGenerated: 2))
    }

    func testStopsWithTrailingWhitespaceAfterPeriod() {
        XCTAssertTrue(DecodeStopPolicy.shouldStop(accumulated: "All done. ", tokensGenerated: 3))
    }

    func testDoesNotStopOnAbbreviation() {
        XCTAssertFalse(DecodeStopPolicy.shouldStop(accumulated: "Please meet Dr.", tokensGenerated: 3))
    }

    func testDoesNotStopOnInitialism() {
        XCTAssertFalse(DecodeStopPolicy.shouldStop(accumulated: "Made in the U.S.", tokensGenerated: 4))
    }

    func testDoesNotStopMidDecimal() {
        XCTAssertFalse(DecodeStopPolicy.shouldStop(accumulated: "Pi is about 3.14", tokensGenerated: 4))
    }

    func testDoesNotStopWithoutTerminator() {
        XCTAssertFalse(DecodeStopPolicy.shouldStop(accumulated: "still going strong", tokensGenerated: 5))
    }

    func testRespectsCustomMinimum() {
        XCTAssertFalse(
            DecodeStopPolicy.shouldStop(accumulated: "Hi.", tokensGenerated: 2, minimumTokens: 3)
        )
        XCTAssertTrue(
            DecodeStopPolicy.shouldStop(accumulated: "Hi.", tokensGenerated: 3, minimumTokens: 3)
        )
    }
}
