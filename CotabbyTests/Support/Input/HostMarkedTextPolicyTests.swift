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
