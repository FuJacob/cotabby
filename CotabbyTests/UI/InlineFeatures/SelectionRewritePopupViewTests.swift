import XCTest
@testable import Cotabby

/// A long preview scrolls inside a bounded height, so Replace, Copy and Retry stay on screen.
final class SelectionRewritePopupViewTests: XCTestCase {
    func test_shortPreviewIsShownWhole() {
        XCTAssertFalse(SelectionRewritePopupView.previewNeedsScrolling("Could you send me the report when you get a chance?"))
    }

    func test_longPreviewScrolls() {
        let paragraph = String(repeating: "Please let me know if the dates work for you. ", count: 12)
        let long = Array(repeating: paragraph, count: 5).joined(separator: "\n\n")
        XCTAssertTrue(SelectionRewritePopupView.previewNeedsScrolling(long))
    }
}
