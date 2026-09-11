import XCTest
@testable import Cotabby

final class HostMarkedTextPolicyTests: XCTestCase {
    /// Measured live in TextEdit: after typing "The quick brown fox ju" the host showed its own
    /// prediction "mps"; AXValue read "The quick brown fox jumps" with the selection at 22 and the
    /// marked range at 22...25.
    func testInlinePredictionAfterTheCaretIsRemoved() {
        let stripped = HostMarkedTextPolicy.strippingPredictionAfterCaret(
            text: "The quick brown fox jumps",
            selection: NSRange(location: 22, length: 0),
            markedRange: NSRange(location: 22, length: 3)
        )
        XCTAssertEqual(stripped, "The quick brown fox ju")
    }

    func testPredictionAfterOtherTrailingTextIsRemovedOnlyWhereItSits() {
        let stripped = HostMarkedTextPolicy.strippingPredictionAfterCaret(
            text: "abc XYZ def",
            selection: NSRange(location: 3, length: 0),
            markedRange: NSRange(location: 4, length: 3)
        )
        XCTAssertEqual(stripped, "abc  def")
    }

    func testCompositionBeforeTheCaretIsKept() {
        let text = "こんにちは"
        let kept = HostMarkedTextPolicy.strippingPredictionAfterCaret(
            text: text,
            selection: NSRange(location: 5, length: 0),
            markedRange: NSRange(location: 0, length: 5)
        )
        XCTAssertEqual(kept, text)
    }

    func testMarkedSpanOverlappingTheCaretIsKept() {
        let kept = HostMarkedTextPolicy.strippingPredictionAfterCaret(
            text: "hello world",
            selection: NSRange(location: 5, length: 0),
            markedRange: NSRange(location: 3, length: 4)
        )
        XCTAssertEqual(kept, "hello world")
    }

    /// Gmail's compose body (2026-09-11): Smart Compose's gray suggestion and its "tab" key hint
    /// read as text after the caret. The span through the hint is Gmail's; a signature below it is
    /// the user's.
    func testGmailsSmartComposeSuggestionIsTheHostsPrediction() {
        let gmail = "https://mail.google.com/mail/u/0/#inbox?compose=new"
        let typed = "It took a "
        let caret = NSRange(location: (typed as NSString).length, length: 0)
        XCTAssertEqual(
            HostMarkedTextPolicy.smartComposeSuggestionRange(text: typed + "lot of time\ntab", selection: caret, urlString: gmail),
            NSRange(location: caret.location, length: ("lot of time\ntab" as NSString).length)
        )
        XCTAssertEqual(
            HostMarkedTextPolicy.smartComposeSuggestionRange(text: typed + "the app\ntab\n\n--\nMason", selection: caret, urlString: gmail),
            NSRange(location: caret.location, length: ("the app\ntab" as NSString).length)
        )
    }

    func testOnlyGmailsSmartComposeShapeIsTheHostsPrediction() {
        let gmail = "https://mail.google.com/mail/u/0/"
        let caret = NSRange(location: 3, length: 0)
        func range(_ text: String, _ selection: NSRange = NSRange(location: 3, length: 0), _ url: String? = gmail) -> NSRange? {
            HostMarkedTextPolicy.smartComposeSuggestionRange(text: text, selection: selection, urlString: url)
        }
        XCTAssertNotNil(range("abcdef\ntab"))
        XCTAssertNil(range("abcdef\ntab", caret, "https://example.com/"), "another site")
        XCTAssertNil(range("abcdef\ntab", caret, nil), "no page address")
        XCTAssertNil(range("abcdef\ntabular"), "a line that only starts with the hint")
        XCTAssertNil(range("abcdef"), "no hint")
        XCTAssertNil(range("abc\ntab"), "nothing suggested before the hint")
        XCTAssertNil(range("abcdef\ntab", NSRange(location: 3, length: 2)), "a selection")
    }

    func testOutOfBoundsOrEmptyRangesAreIgnoredOrClamped() {
        XCTAssertEqual(
            HostMarkedTextPolicy.strippingPredictionAfterCaret(
                text: "abc", selection: NSRange(location: 3, length: 0), markedRange: NSRange(location: 7, length: 2)
            ),
            "abc"
        )
        XCTAssertEqual(
            HostMarkedTextPolicy.strippingPredictionAfterCaret(
                text: "abc", selection: NSRange(location: 1, length: 0), markedRange: NSRange(location: 2, length: 0)
            ),
            "abc"
        )
        XCTAssertEqual(
            HostMarkedTextPolicy.strippingPredictionAfterCaret(
                text: "abcdef", selection: NSRange(location: 2, length: 0), markedRange: NSRange(location: 4, length: 40)
            ),
            "abcd"
        )
    }
}
