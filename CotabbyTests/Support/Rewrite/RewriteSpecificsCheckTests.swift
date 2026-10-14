import XCTest
@testable import Cotabby

/// A rewrite may change wording and tone, but a number or name the user did not write is flagged,
/// so Replace needs a deliberate click.
final class RewriteSpecificsCheckTests: XCTestCase {
    func test_changedNumberIsFlagged() {
        XCTAssertEqual(
            RewriteSpecificsCheck.unsupportedSpecifics(in: "I'm 100% sure.", source: "im 1000% sure"),
            ["100"]
        )
    }

    func test_numbersCompareByDigits() {
        XCTAssertTrue(RewriteSpecificsCheck.unsupportedSpecifics(in: "It costs 4000 EUR.", source: "it costs 4.000 eur").isEmpty)
    }

    func test_addedNameIsFlagged() {
        XCTAssertEqual(
            RewriteSpecificsCheck.unsupportedSpecifics(in: "Let me know, Sam.", source: "let me know"),
            ["Sam"]
        )
    }

    func test_namesFromTheSourceAreFineIgnoringCaseDiacriticsAndPlurals() {
        XCTAssertTrue(RewriteSpecificsCheck.unsupportedSpecifics(in: "Thanks, Zoë. I sent the NDAs.", source: "thanks zoe i sent the nda").isEmpty)
    }

    func test_sentenceOpenersAndPronounsAreNotNames() {
        XCTAssertTrue(RewriteSpecificsCheck.unsupportedSpecifics(in: "Sure. Could you send it? I can wait.", source: "send it").isEmpty)
    }
}
