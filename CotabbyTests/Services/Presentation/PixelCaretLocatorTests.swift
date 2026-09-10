import XCTest
@testable import Cotabby

/// The pure half of the locator: mapping the analyzer's rows and columns back to a caret box on
/// screen. Numbers follow the measured Obsidian paragraph (union run 605x44 at 2x, two lines of
/// 24pt pitch, 20pt line boxes).
final class PixelCaretLocatorTests: XCTestCase {
    private let frame = CGRect(x: 608, y: 700, width: 605, height: 44)   // Cocoa: bottom-left origin
    private var region: CGRect { frame.insetBy(dx: -PixelCaretLocator.padding, dy: -PixelCaretLocator.padding) }

    private func request(text: String = "the end of the paragraph", pitch: CGFloat? = nil) -> PixelCaretLocator.Request {
        PixelCaretLocator.Request(
            focusedInputIdentityKey: 1, runFrame: frame, paragraphTextBeforeCaret: text,
            siblingLinePitch: pitch, siblingLineBoxHeight: nil, spaceAdvance: 4.5
        )
    }

    /// Two painted lines: rows measured at 2x inside a region padded by 6pt. Line 2's ink ends at
    /// column 1029, i.e. 6pt of padding plus 508.5pt into the run.
    func testCaretSitsAfterTheLastLinesInkOnTheLastLineBox() throws {
        let analysis = InkCaretAnalyzer.Measurement(
            lines: [
                .init(topRow: 20, bottomRow: 50, inkLeftColumn: 24, inkRightColumn: 1200),
                .init(topRow: 68, bottomRow: 98, inkLeftColumn: 26, inkRightColumn: 1029)
            ],
            pitchRows: 48
        )
        let measured = try XCTUnwrap(PixelCaretLocator.measurement(from: analysis, scale: 2, region: region, request: request()))
        XCTAssertEqual(measured.lineCount, 2)
        XCTAssertEqual(measured.lineIndex, 1)
        XCTAssertEqual(try XCTUnwrap(measured.linePitch), 24, accuracy: 0.01)
        // Second line box: top at frame.maxY - 24, 20pt tall (44 - 24).
        XCTAssertEqual(measured.caretRect.maxY, frame.maxY - 24, accuracy: 0.01)
        XCTAssertEqual(measured.caretRect.height, 20, accuracy: 0.01)
        // x: region.minX + (1029 + 1) / 2 + the ink-to-caret gap.
        XCTAssertEqual(measured.caretRect.minX, region.minX + 515 + PixelCaretLocator.inkToCaretGap, accuracy: 0.01)
        XCTAssertEqual(measured.lineRect.minX, frame.minX)
    }

    func testTrailingSpacesAdvanceTheCaretPastTheInk() throws {
        let analysis = InkCaretAnalyzer.Measurement(
            lines: [.init(topRow: 12, bottomRow: 42, inkLeftColumn: 24, inkRightColumn: 400)], pitchRows: nil
        )
        let single = CGRect(x: 608, y: 700, width: 418, height: 20)
        let req = PixelCaretLocator.Request(
            focusedInputIdentityKey: 1, runFrame: single, paragraphTextBeforeCaret: "ends with two  ",
            siblingLinePitch: nil, siblingLineBoxHeight: nil, spaceAdvance: 4.5
        )
        let reg = single.insetBy(dx: -PixelCaretLocator.padding, dy: -PixelCaretLocator.padding)
        let measured = try XCTUnwrap(PixelCaretLocator.measurement(from: analysis, scale: 2, region: reg, request: req))
        XCTAssertEqual(measured.lineCount, 1)
        XCTAssertEqual(measured.caretRect.height, 20, accuracy: 0.01)
        XCTAssertEqual(measured.caretRect.minX, reg.minX + 200.5 + PixelCaretLocator.inkToCaretGap + 9, accuracy: 0.01)
    }

    /// The frame holds two line boxes (44 = 20 + 24) but only one line was painted: the paragraph
    /// wrapped exactly at its end, so the caret is at the start of the blank second line.
    func testBlankLastLinePutsTheCaretAtTheContentEdge() throws {
        let analysis = InkCaretAnalyzer.Measurement(
            lines: [.init(topRow: 20, bottomRow: 50, inkLeftColumn: 24, inkRightColumn: 1200)], pitchRows: nil
        )
        let measured = try XCTUnwrap(PixelCaretLocator.measurement(from: analysis, scale: 2, region: region, request: request(pitch: 24)))
        XCTAssertEqual(measured.lineCount, 2)
        XCTAssertEqual(measured.lineIndex, 1)
        XCTAssertEqual(measured.caretRect.minX, frame.minX + (24 / 2 - PixelCaretLocator.padding), accuracy: 0.01)
        XCTAssertEqual(measured.caretRect.maxY, frame.maxY - 24, accuracy: 0.01)
    }

    func testInkOutsideItsLineBoxIsRefused() {
        // Ink rows that place the "last line" above the box the frame assigns it: a foreign capture.
        let analysis = InkCaretAnalyzer.Measurement(
            lines: [
                .init(topRow: 2, bottomRow: 8, inkLeftColumn: 24, inkRightColumn: 1200),
                .init(topRow: 10, bottomRow: 16, inkLeftColumn: 26, inkRightColumn: 1029)
            ],
            pitchRows: 8
        )
        XCTAssertNil(PixelCaretLocator.measurement(from: analysis, scale: 2, region: region, request: request()))
    }
}
