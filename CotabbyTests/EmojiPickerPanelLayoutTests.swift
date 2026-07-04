import XCTest
@testable import Cotabby

/// Tests for the pure emoji picker panel geometry.
///
/// AppKit screen coordinates are bottom-left origin, so "below the caret" means a smaller y. These
/// pin down the placement rules the controller depends on: prefer below, flip above near the bottom,
/// and never let the panel slide off any edge of the target screen.
final class EmojiPickerPanelLayoutTests: XCTestCase {

    private let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func test_contentSize_reservesRibbonRowWhenEmpty() {
        let size = EmojiPickerMetrics.contentSize(matchCount: 0)
        let expectedHeight = EmojiPickerMetrics.queryRowHeight + EmojiPickerMetrics.ribbonRowHeight

        XCTAssertEqual(size.width, EmojiPickerMetrics.minWidth)
        XCTAssertEqual(size.height, expectedHeight)
    }

    func test_contentSize_capsAtMaxVisibleCells() {
        let size = EmojiPickerMetrics.contentSize(matchCount: 20)
        let cells = CGFloat(EmojiPickerMetrics.maxVisibleCells)
        let expectedWidth = cells * EmojiPickerMetrics.cellSize
            + (cells - 1) * EmojiPickerMetrics.cellSpacing
            + EmojiPickerMetrics.horizontalInset * 2

        XCTAssertEqual(size.width, expectedWidth)
        XCTAssertEqual(size.height, EmojiPickerMetrics.queryRowHeight + EmojiPickerMetrics.ribbonRowHeight)
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
        // Caret far enough right that even the compact ribbon overflows the visible frame.
        let caret = CGRect(x: 950, y: 400, width: 2, height: 16)
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
