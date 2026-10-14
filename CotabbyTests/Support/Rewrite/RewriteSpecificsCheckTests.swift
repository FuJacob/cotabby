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

    /// A name the user never wrote is flagged even when the source holds it inside a longer word.
    func test_namesMatchWholeWordsOnly() {
        XCTAssertEqual(RewriteSpecificsCheck.unsupportedSpecifics(in: "Thanks, Sam.", source: "the same works"), ["Sam"])
        XCTAssertEqual(RewriteSpecificsCheck.unsupportedSpecifics(in: "Sure. Ask Al.", source: "ask all of them"), ["Al"])
    }

    /// Decimal points and times keep their value: 3.5 is not 35, and 1:30 is not 13:0.
    func test_decimalsAndTimesKeepTheirValue() {
        XCTAssertEqual(RewriteSpecificsCheck.unsupportedSpecifics(in: "It takes 35 minutes.", source: "it takes 3.5 minutes"), ["35"])
        XCTAssertEqual(RewriteSpecificsCheck.unsupportedSpecifics(in: "See you at 13:0.", source: "see you at 1:30"), ["13:0"])
        XCTAssertTrue(RewriteSpecificsCheck.unsupportedSpecifics(in: "It takes 3,5 minutes.", source: "it takes 3.5 minutes").isEmpty)
        XCTAssertTrue(RewriteSpecificsCheck.unsupportedSpecifics(in: "Meet at 1:30.", source: "meet at 1:30").isEmpty)
    }

    func test_thousandsSeparatorsDoNotMatter() {
        XCTAssertEqual(RewriteSpecificsCheck.numbers(in: "4,000 and 4.000 and 1,234,567"), ["4000", "4000", "1234567"])
    }
}
