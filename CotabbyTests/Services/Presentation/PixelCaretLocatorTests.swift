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

    /// The baseline read from the same capture rides along as an offset below the caret box top.
    func testTheCaretLinesBaselineComesFromTheSameCapture() throws {
        let analysis = InkCaretAnalyzer.Measurement(
            lines: [
                .init(topRow: 20, bottomRow: 50, inkLeftColumn: 24, inkRightColumn: 1200, baselineRow: 44),
                .init(topRow: 68, bottomRow: 98, inkLeftColumn: 26, inkRightColumn: 1029, baselineRow: 92)
            ],
            pitchRows: 48
        )
        let measured = try XCTUnwrap(PixelCaretLocator.measurement(from: analysis, scale: 2, region: region, request: request()))
        // Second line box top is frame.maxY - 24; the baseline row 92 is 46pt below the region top,
        // i.e. region.maxY - 46 = frame.maxY + 6 - 46 = frame.maxY - 40: 16pt below the box top.
        XCTAssertEqual(try XCTUnwrap(measured.baselineOffsetFromTop), 16, accuracy: 0.01)
    }

    func testALoneGlyphsBaselineIsNotReported() throws {
        // 20 device pixels of ink (one glyph): the baseline is read from the caret box's line box
        // policy instead, because a single glyph's bottom is a row too high (measured in Obsidian).
        let analysis = InkCaretAnalyzer.Measurement(
            lines: [.init(topRow: 20, bottomRow: 50, inkLeftColumn: 24, inkRightColumn: 44, baselineRow: 44)], pitchRows: nil
        )
        let single = CGRect(x: 608, y: 700, width: 418, height: 20)
        let req = PixelCaretLocator.Request(
            focusedInputIdentityKey: 1, runFrame: single, paragraphTextBeforeCaret: "A", siblingLinePitch: nil, siblingLineBoxHeight: nil, spaceAdvance: 4.5
        )
        let reg = single.insetBy(dx: -PixelCaretLocator.padding, dy: -PixelCaretLocator.padding)
        let measured = try XCTUnwrap(PixelCaretLocator.measurement(from: analysis, scale: 2, region: reg, request: req))
        XCTAssertNil(measured.baselineOffsetFromTop)
    }

    func testABaselineOutsideTheLineBoxIsNotReported() throws {
        let analysis = InkCaretAnalyzer.Measurement(
            lines: [.init(topRow: 20, bottomRow: 50, inkLeftColumn: 24, inkRightColumn: 400, baselineRow: 4)], pitchRows: nil
        )
        let single = CGRect(x: 608, y: 700, width: 418, height: 20)
        let req = PixelCaretLocator.Request(
            focusedInputIdentityKey: 1, runFrame: single, paragraphTextBeforeCaret: "ends", siblingLinePitch: nil, siblingLineBoxHeight: nil, spaceAdvance: 4.5
        )
        let reg = single.insetBy(dx: -PixelCaretLocator.padding, dy: -PixelCaretLocator.padding)
        let measured = try XCTUnwrap(PixelCaretLocator.measurement(from: analysis, scale: 2, region: reg, request: req))
        XCTAssertNil(measured.baselineOffsetFromTop)
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

/// The single-line measurement (Chrome's address bar, measured 2026-09-10: a 598x24pt field whose
/// text ink ran from column 2 to 475 at 2x, rows 13 to 38, with nothing else painted in the frame).
final class PixelCaretLocatorSingleLineTests: XCTestCase {
    private let frame = CGRect(x: 279, y: 914, width: 598, height: 24)   // Cocoa: bottom-left origin
    private var region: CGRect { frame.insetBy(dx: -PixelCaretLocator.padding, dy: -PixelCaretLocator.padding) }

    private func request(text: String) -> PixelCaretLocator.Request {
        PixelCaretLocator.Request(
            focusedInputIdentityKey: 9, runFrame: frame, paragraphTextBeforeCaret: text,
            siblingLinePitch: nil, siblingLineBoxHeight: nil, spaceAdvance: 4, singleLineCaretHeight: 16
        )
    }

    func testCaretFollowsTheInkAndTheBoxIsCentredOnIt() throws {
        // The region is padded by 6pt, so the field's column 475 is region column 475 + 12.
        let analysis = InkCaretAnalyzer.Measurement(
            lines: [.init(topRow: 25, bottomRow: 50, inkLeftColumn: 14, inkRightColumn: 487)], pitchRows: nil
        )
        let measured = try XCTUnwrap(PixelCaretLocator.measurement(from: analysis, scale: 2, region: region, request: request(text: "hi sarah thanks for sending the draft")))
        XCTAssertEqual(measured.lineCount, 1)
        XCTAssertNil(measured.linePitch)
        XCTAssertEqual(measured.caretRect.minX, region.minX + 244 + PixelCaretLocator.inkToCaretGap, accuracy: 0.01)
        XCTAssertEqual(measured.caretRect.height, 16, accuracy: 0.01)
        // Ink spans 12.5pt to 25.5pt below the region top; its centre is the box's centre.
        let inkCentre = region.maxY - (12.5 + 25.5) / 2
        XCTAssertEqual(measured.caretRect.midY, inkCentre, accuracy: 0.01)
        XCTAssertEqual(measured.lineRect.minX, frame.minX)
        XCTAssertEqual(measured.lineRect.width, frame.width)
    }

    func testTheBoxStaysInsideTheFrameAndTrailingSpacesCount() throws {
        // Ink hugging the top edge: the box is clamped to the frame rather than poking above it.
        let analysis = InkCaretAnalyzer.Measurement(
            lines: [.init(topRow: 10, bottomRow: 22, inkLeftColumn: 14, inkRightColumn: 100)], pitchRows: nil
        )
        let measured = try XCTUnwrap(PixelCaretLocator.measurement(from: analysis, scale: 2, region: region, request: request(text: "go  ")))
        XCTAssertEqual(measured.caretRect.maxY, frame.maxY, accuracy: 0.01)
        XCTAssertEqual(measured.caretRect.minX, region.minX + 50.5 + PixelCaretLocator.inkToCaretGap + 8, accuracy: 0.01)
    }

    func testInkOutsideTheFrameIsRefused() {
        let analysis = InkCaretAnalyzer.Measurement(
            lines: [.init(topRow: 0, bottomRow: 3, inkLeftColumn: 14, inkRightColumn: 100)], pitchRows: nil
        )
        // Rows 0-3 sit in the padding above the frame: not the field's text.
        XCTAssertNil(PixelCaretLocator.measurement(from: analysis, scale: 2, region: region.offsetBy(dx: 0, dy: 40), request: request(text: "go")))
    }
}
