import XCTest
@testable import Ghostype

/// Pins the macOS smart-quote placement `SmartQuoteSubstitution` mirrors: a quote opens at the start,
/// after whitespace, or after an opening bracket/quote, and closes otherwise; the text before the
/// caret decides the first quote.
final class SmartQuoteSubstitutionTests: XCTestCase {
    func test_doubleQuotesOpenAfterSpaceAndCloseAfterWords() {
        XCTAssertEqual(SmartQuoteSubstitution.apply(" \"hello\" there", precedingText: "She said"), " “hello” there")
    }

    func test_caretContextDecidesTheFirstQuote() {
        XCTAssertEqual(SmartQuoteSubstitution.apply("\" and left", precedingText: "She said \"hi"), "” and left")
        XCTAssertEqual(SmartQuoteSubstitution.apply("\"quoted\"", precedingText: "("), "“quoted”")
        XCTAssertEqual(SmartQuoteSubstitution.apply("\"start\"", precedingText: ""), "“start”")
    }

    func test_apostrophesInsideWordsCurlAsClosingQuotes() {
        XCTAssertEqual(SmartQuoteSubstitution.apply("'t do that, it's 'fine'", precedingText: "I don"), "’t do that, it’s ‘fine’")
    }

    func test_nestedOpeningQuotes() {
        XCTAssertEqual(SmartQuoteSubstitution.apply(" \"'Tis\"", precedingText: "He wrote"), " “‘Tis”")
    }

    func test_textWithoutQuotesIsUnchanged() {
        XCTAssertEqual(SmartQuoteSubstitution.apply(" plain words.", precedingText: "Some"), " plain words.")
    }
}
