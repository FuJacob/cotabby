import XCTest
@testable import Cotabby

/// Tests for the pure emoji picker panel geometry.
///
/// AppKit screen coordinates are bottom-left origin, so "below the caret" means a smaller y. These
/// pin down the placement rules the controller depends on: prefer below, flip above near the bottom,
/// and never let the panel slide off any edge of the target screen.
final class EmojiPickerPanelLayoutTests: XCTestCase {

    private let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func test_contentSize_reservesOneRowWhenEmpty() {
        let size = EmojiPickerMetrics.contentSize(matchCount: 0)
        let expectedHeight = EmojiPickerMetrics.headerHeight
            + EmojiPickerMetrics.dividerHeight
            + EmojiPickerMetrics.rowHeight

        XCTAssertEqual(size.width, EmojiPickerMetrics.width)
        XCTAssertEqual(size.height, expectedHeight)
    }

    func test_contentSize_capsAtMaxVisibleRows() {
        let size = EmojiPickerMetrics.contentSize(matchCount: 20)
        let visibleRowsHeight = CGFloat(EmojiPickerMetrics.maxVisibleRows) * EmojiPickerMetrics.rowHeight
            + EmojiPickerMetrics.listVerticalPadding
        let expectedHeight = EmojiPickerMetrics.headerHeight
            + EmojiPickerMetrics.dividerHeight
            + visibleRowsHeight

        XCTAssertEqual(size.height, expectedHeight)
    }

    func test_frame_sitsBelowCaretWhenItFits() {
        let caret = CGRect(x: 200, y: 400, width: 2, height: 16)
        let size = EmojiPickerMetrics.contentSize(matchCount: 5)

        let frame = EmojiPickerPanelLayout.frame(caretRect: caret, contentSize: size, visibleFrame: visibleFrame)

        XCTAssertEqual(frame.origin.x, 200)
        XCTAssertEqual(frame.maxY, caret.minY - EmojiPickerPanelLayout.caretGap)
    }

    func test_frame_flipsAboveCaretNearBottom() {
        let caret = CGRect(x: 200, y: 20, width: 2, height: 16)
        let size = EmojiPickerMetrics.contentSize(matchCount: 5)

        let frame = EmojiPickerPanelLayout.frame(caretRect: caret, contentSize: size, visibleFrame: visibleFrame)

        XCTAssertEqual(frame.origin.y, caret.maxY + EmojiPickerPanelLayout.caretGap)
        XCTAssertLessThanOrEqual(frame.maxY, visibleFrame.maxY)
    }

    func test_frame_clampsToRightEdge() {
        let caret = CGRect(x: 850, y: 400, width: 2, height: 16)
        let size = EmojiPickerMetrics.contentSize(matchCount: 3)

        let frame = EmojiPickerPanelLayout.frame(caretRect: caret, contentSize: size, visibleFrame: visibleFrame)

        XCTAssertEqual(frame.maxX, visibleFrame.maxX)
    }

    func test_frame_clampsToLeftEdge() {
        let caret = CGRect(x: -50, y: 400, width: 2, height: 16)
        let size = EmojiPickerMetrics.contentSize(matchCount: 3)

        let frame = EmojiPickerPanelLayout.frame(caretRect: caret, contentSize: size, visibleFrame: visibleFrame)

        XCTAssertEqual(frame.origin.x, visibleFrame.minX)
    }
}
