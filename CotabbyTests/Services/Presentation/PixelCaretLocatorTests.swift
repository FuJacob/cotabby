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

    // MARK: - A caret with text after it on its line

    /// The ink the analyzer would report for `lines` set in `font` at 2x from the run's left edge
    /// (6pt into the region), `pitchRows` apart: each line's ink from its first glyph's left side
    /// bearing to its last word's advance.
    private func inkLines(_ lines: [String], font: NSFont, pitchRows: Int = 44) -> [InkCaretAnalyzer.Line] {
        lines.enumerated().map { index, text in
            let trimmed = text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let width = GhostFontResolver.width(of: trimmed, font: font)
            let bearing = PixelCaretLocator.leftSideBearing(of: text as NSString, at: 0, font: font)
            let top = 19 + index * pitchRows
            return InkCaretAnalyzer.Line(
                topRow: top, bottomRow: top + 30,
                inkLeftColumn: Int(((PixelCaretLocator.padding + bearing) * 2).rounded()),
                inkRightColumn: Int(((PixelCaretLocator.padding + width) * 2).rounded()) - 1,
                baselineRow: top + 23
            )
        }
    }

    private let composerFirstLine = "There are still things to work on: perfecting the positioning of the text, making sure a "
    private let composerSecondLine = "prediction appears where it should, and much more."
    private let composerFrame = CGRect(x: 342, y: 51, width: 670, height: 41)

    /// Measured 2026-09-11 in Claude's composer: the caret moved back before ", " on a paragraph's
    /// second line, and the card stood under the field's right edge. The text before the caret,
    /// walked through the lines' ink, puts it on the second line after "should".
    func testAMidLineCaretIsFoundAmongTheLinesByTheTextBeforeIt() throws {
        let font = NSFont.systemFont(ofSize: 15.3)
        let region = composerFrame.insetBy(dx: -PixelCaretLocator.padding, dy: -PixelCaretLocator.padding)
        let lines = inkLines([composerFirstLine, composerSecondLine], font: font)
        let placement = try XCTUnwrap(PixelCaretLocator.midLineCaret(
            lines: lines, scale: 2, region: region, text: composerFirstLine + "prediction appears where it should", font: font
        ))
        XCTAssertEqual(placement.lineIndex, 1)
        XCTAssertEqual(placement.x, composerFrame.minX + GhostFontResolver.width(of: "prediction appears where it should", font: font), accuracy: 1)

        let early = try XCTUnwrap(PixelCaretLocator.midLineCaret(lines: lines, scale: 2, region: region, text: "There are still things", font: font))
        XCTAssertEqual(early.lineIndex, 0, "text after the caret on the first line keeps it there")
        XCTAssertEqual(early.x, composerFrame.minX + GhostFontResolver.width(of: "There are still things", font: font), accuracy: 1)
    }

    /// A word the host moved to the next line whole takes the caret inside it along.
    func testACaretInsideAWordTheHostWrappedIsOnTheNextLine() throws {
        let font = NSFont.systemFont(ofSize: 15.3)
        let region = composerFrame.insetBy(dx: -PixelCaretLocator.padding, dy: -PixelCaretLocator.padding)
        let lines = inkLines([composerFirstLine, composerSecondLine], font: font)
        let placement = try XCTUnwrap(PixelCaretLocator.midLineCaret(
            lines: lines, scale: 2, region: region, text: composerFirstLine + "predic", font: font
        ))
        XCTAssertEqual(placement.lineIndex, 1)
        XCTAssertEqual(placement.x, composerFrame.minX + GhostFontResolver.width(of: "predic", font: font), accuracy: 1)
    }

    /// Ink that ends between two word ends by more than the tolerance is not this text in this face.
    func testInkThatEndsAtNoWordIsNoPlacement() {
        let font = NSFont.systemFont(ofSize: 15.3)
        let region = composerFrame.insetBy(dx: -PixelCaretLocator.padding, dy: -PixelCaretLocator.padding)
        let short = GhostFontResolver.width(of: "There are still", font: font)
        let long = GhostFontResolver.width(of: "There are still things", font: font)
        let between = (short + long) / 2
        let lines = [
            InkCaretAnalyzer.Line(topRow: 19, bottomRow: 49, inkLeftColumn: 12, inkRightColumn: 12 + Int(between * 2), baselineRow: 42),
            InkCaretAnalyzer.Line(topRow: 63, bottomRow: 93, inkLeftColumn: 12, inkRightColumn: 900, baselineRow: 86)
        ]
        XCTAssertNil(PixelCaretLocator.midLineCaret(
            lines: lines, scale: 2, region: region, text: "There are still things to work on: perfecting", font: font
        ))
    }

    /// The read gives the caret's own line box (the second of two, 22pt apart) and no ink width: that
    /// line's ink runs on past the caret.
    func testAMidLineReadGivesTheCaretsLineBoxAndNoInkWidth() throws {
        let font = NSFont.systemFont(ofSize: 15.3)
        let region = composerFrame.insetBy(dx: -PixelCaretLocator.padding, dy: -PixelCaretLocator.padding)
        let analysis = InkCaretAnalyzer.Measurement(lines: inkLines([composerFirstLine, composerSecondLine], font: font), pitchRows: 44)
        let request = PixelCaretLocator.Request(
            focusedInputIdentityKey: 1, runFrame: composerFrame,
            paragraphTextBeforeCaret: composerFirstLine + "prediction appears where it should",
            siblingLinePitch: nil, siblingLineBoxHeight: nil, spaceAdvance: 4, font: font, caretIsMidLine: true
        )
        let measured = try XCTUnwrap(PixelCaretLocator.measurement(from: analysis, scale: 2, region: region, request: request))
        XCTAssertEqual(measured.lineIndex, 1)
        XCTAssertEqual(measured.caretRect.maxY, composerFrame.maxY - 22, accuracy: 0.01)
        XCTAssertEqual(measured.caretRect.height, 19, accuracy: 0.01)
        XCTAssertNil(measured.lineInkWidth)
        XCTAssertEqual(try XCTUnwrap(measured.linePitch), 22, accuracy: 0.01)
        XCTAssertNotEqual(request.cacheKey, PixelCaretLocator.Request(
            focusedInputIdentityKey: 1, runFrame: composerFrame, paragraphTextBeforeCaret: request.paragraphTextBeforeCaret,
            siblingLinePitch: nil, siblingLineBoxHeight: nil, spaceAdvance: 4, font: font
        ).cacheKey, "a caret read at the ink's end never stands in for one inside the line")
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

    func testTheCaretGapIsTheLastGlyphsOwnSideBearing() throws {
        // Measured in Obsidian (2026-09-10): a fixed gap after a "t" in the system face put the
        // ghost half a point right of the accepted text. Each glyph's bearing is its own.
        let font = NSFont.systemFont(ofSize: 16)
        let afterT = try XCTUnwrap(PixelCaretLocator.trailingInkGap(after: "the ghost", font: font))
        let afterO = try XCTUnwrap(PixelCaretLocator.trailingInkGap(after: "hello", font: font))
        XCTAssertTrue(PixelCaretLocator.trailingInkGapRange.contains(afterT))
        XCTAssertTrue(PixelCaretLocator.trailingInkGapRange.contains(afterO))
        XCTAssertNotEqual(afterT, afterO, accuracy: 0.05, "two glyphs with different bearings must not share one gap")
        XCTAssertEqual(PixelCaretLocator.trailingInkGap(after: "the ghost ", font: font), afterT, "trailing spaces are added separately")
        XCTAssertNil(PixelCaretLocator.trailingInkGap(after: "   ", font: font))
        XCTAssertNil(PixelCaretLocator.trailingInkGap(after: "", font: font))
    }

    /// The host's own caret bar, caught right after a glyph, is the caret: its centre, with no side
    /// bearing added, and the text's ink width stops before it.
    func testTheHostsCaretBarIsTheCaret() throws {
        var caretLine = InkCaretAnalyzer.Line(topRow: 68, bottomRow: 98, inkLeftColumn: 26, inkRightColumn: 1030)
        caretLine.caretBarColumns = 1029...1030
        caretLine.glyphRightColumn = 1012
        let analysis = InkCaretAnalyzer.Measurement(
            lines: [.init(topRow: 20, bottomRow: 50, inkLeftColumn: 24, inkRightColumn: 1200), caretLine],
            pitchRows: 48
        )
        let measured = try XCTUnwrap(PixelCaretLocator.measurement(
            from: analysis, scale: 2, region: region, request: request(text: "the end of the paragraph")
        ))
        // Columns 1029-1030 cover 1029px to 1031px; their centre is 1030px, 515pt into the region.
        XCTAssertEqual(measured.caretRect.minX, region.minX + 515, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(measured.lineInkWidth), CGFloat(1012 - 26 + 1) / 2, accuracy: 0.01)
    }

    /// After a trailing space the host's bar stops short of the space's full advance, while the next
    /// character lands at it (Obsidian, 2026-09-10): the caret is the text's own ink edge, the bar
    /// left out, plus the glyph's bearing and the space.
    func testAfterATrailingSpaceTheTextsInkPlacesTheCaretNotTheBar() throws {
        var caretLine = InkCaretAnalyzer.Line(topRow: 68, bottomRow: 98, inkLeftColumn: 26, inkRightColumn: 1030)
        caretLine.caretBarColumns = 1029...1030
        caretLine.glyphRightColumn = 1012
        let analysis = InkCaretAnalyzer.Measurement(
            lines: [.init(topRow: 20, bottomRow: 50, inkLeftColumn: 24, inkRightColumn: 1200), caretLine],
            pitchRows: 48
        )
        let measured = try XCTUnwrap(PixelCaretLocator.measurement(
            from: analysis, scale: 2, region: region, request: request(text: "the end of the paragraph ")
        ))
        // Text ink ends at 1013px (506.5pt); then the default bearing and one 4.5pt space.
        XCTAssertEqual(measured.caretRect.minX, region.minX + 506.5 + PixelCaretLocator.inkToCaretGap + 4.5, accuracy: 0.01)
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

    /// Measured 2026-09-11 in Claude's composer: an "E" typed onto a fresh line gave no pitch its
    /// lines could have (`InkCaretAnalyzer.pitchRows(of:)`), and the frame arithmetic then made three
    /// 12.5pt line boxes out of two lines. With no pitch the painted lines share the frame: the caret
    /// is on the second line, after the "E", and no pitch is reported for the rows to step by.
    func testTwoLinesWithNoPitchShareTheFrame() throws {
        let composer = CGRect(x: 342, y: 51, width: 670, height: 41)
        let region = composer.insetBy(dx: -PixelCaretLocator.padding, dy: -PixelCaretLocator.padding)
        let analysis = InkCaretAnalyzer.Measurement(
            lines: [
                .init(topRow: 19, bottomRow: 49, inkLeftColumn: 12, inkRightColumn: 1343, baselineRow: 42),
                .init(topRow: 56, bottomRow: 93, inkLeftColumn: 14, inkRightColumn: 31, baselineRow: 67)
            ],
            pitchRows: nil
        )
        let request = PixelCaretLocator.Request(
            focusedInputIdentityKey: 1, runFrame: composer, paragraphTextBeforeCaret: "making sure it appears E",
            siblingLinePitch: nil, siblingLineBoxHeight: nil, spaceAdvance: 4
        )
        let measured = try XCTUnwrap(PixelCaretLocator.measurement(from: analysis, scale: 2, region: region, request: request))
        XCTAssertEqual(measured.lineCount, 2)
        XCTAssertEqual(measured.lineIndex, 1)
        XCTAssertEqual(measured.caretRect.minY, composer.minY, accuracy: 0.01)
        XCTAssertEqual(measured.caretRect.height, 20.5, accuracy: 0.01)
        XCTAssertEqual(measured.caretRect.minX, region.minX + 16 + PixelCaretLocator.inkToCaretGap, accuracy: 0.01)
        XCTAssertNil(measured.linePitch)
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

    func testASingleLinesCaretBarIsTheCaret() throws {
        var line = InkCaretAnalyzer.Line(topRow: 14, bottomRow: 60, inkLeftColumn: 14, inkRightColumn: 488)
        line.caretBarColumns = 487...488
        line.glyphRightColumn = 470
        let analysis = InkCaretAnalyzer.Measurement(lines: [line], pitchRows: nil)
        let measured = try XCTUnwrap(PixelCaretLocator.measurement(
            from: analysis, scale: 2, region: region, request: request(text: "hi sarah thanks for the")
        ))
        XCTAssertEqual(measured.caretRect.minX, region.minX + 244, accuracy: 0.01)
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

    /// Ink reaching the region's right edge runs on past it: no caret can be read there.
    func testInkIntoTheRegionsRightEdgeIsRefused() {
        let analysis = InkCaretAnalyzer.Measurement(
            lines: [.init(topRow: 25, bottomRow: 50, inkLeftColumn: 14, inkRightColumn: Int(region.width * 2) - 1)], pitchRows: nil
        )
        XCTAssertNil(PixelCaretLocator.measurement(from: analysis, scale: 2, region: region, request: request(text: "a line that runs on")))
    }

    /// A one-line run inside a paragraph editor is captured in its own line box, a point either
    /// side, never reaching its neighbours' lines four points away.
    func testAOneLineRunIsCapturedInItsOwnLineBox() {
        var oneLine = request(text: "A short second paragraph")
        oneLine.verticalPadding = 1
        XCTAssertEqual(oneLine.captureRegion, frame.insetBy(dx: -PixelCaretLocator.padding, dy: -1))
        XCTAssertEqual(request(text: "go").captureRegion, region, "a single-line field keeps its padding")
    }

    func testInkOutsideTheFrameIsRefused() {
        let analysis = InkCaretAnalyzer.Measurement(
            lines: [.init(topRow: 0, bottomRow: 3, inkLeftColumn: 14, inkRightColumn: 100)], pitchRows: nil
        )
        // Rows 0-3 sit in the padding above the frame: not the field's text.
        XCTAssertNil(PixelCaretLocator.measurement(from: analysis, scale: 2, region: region.offsetBy(dx: 0, dy: 40), request: request(text: "go")))
    }
}

/// Carrying a captured caret forward over text typed since the capture, while the ghost panel
/// lies over the run and a fresh capture would read the panel (Obsidian, 2026-09-10).
final class PixelCaretExtrapolationTests: XCTestCase {
    private let frame = CGRect(x: 608, y: 700, width: 605, height: 44)
    private let font = NSFont.systemFont(ofSize: 16)

    private func request(_ text: String, frame: CGRect? = nil, font: NSFont? = NSFont.systemFont(ofSize: 16)) -> PixelCaretLocator.Request {
        PixelCaretLocator.Request(
            focusedInputIdentityKey: 1, runFrame: frame ?? self.frame, paragraphTextBeforeCaret: text,
            siblingLinePitch: 24, siblingLineBoxHeight: 20, spaceAdvance: 4.5, font: font
        )
    }

    private var base: (request: PixelCaretLocator.Request, measurement: PixelCaretLocator.Measurement) {
        (request("the end of the paragraph"), PixelCaretLocator.Measurement(
            caretRect: CGRect(x: 1000, y: 700, width: 2, height: 20),
            lineRect: CGRect(x: 608, y: 700, width: 605, height: 20),
            linePitch: 24, lineIndex: 1, lineCount: 2, baselineOffsetFromTop: 16, lineInkWidth: 380
        ))
    }

    func testTheCaretMovesByTheTypedTextsAdvanceAndTheLineStays() throws {
        let carried = try XCTUnwrap(PixelCaretLocator.extrapolated(from: base, for: request("the end of the paragraph and")))
        let advance = GhostFontResolver.width(of: " and", font: font)
        XCTAssertEqual(carried.caretRect.minX, 1000 + advance, accuracy: 0.001)
        XCTAssertEqual(carried.caretRect.minY, 700)
        XCTAssertEqual(carried.caretRect.height, 20)
        XCTAssertEqual(carried.lineRect, base.measurement.lineRect)
        XCTAssertEqual(carried.lineIndex, 1)
        XCTAssertEqual(carried.lineCount, 2)
        XCTAssertEqual(try XCTUnwrap(carried.baselineOffsetFromTop), 16)
        XCTAssertEqual(try XCTUnwrap(carried.lineInkWidth), 380 + advance, accuracy: 0.001)
    }

    /// A trailing space typed counts as its advance too: the host's caret sits past it.
    func testATypedSpaceAdvancesTheCaret() throws {
        let carried = try XCTUnwrap(PixelCaretLocator.extrapolated(from: base, for: request("the end of the paragraph ")))
        XCTAssertEqual(carried.caretRect.minX, 1000 + GhostFontResolver.width(of: " ", font: font), accuracy: 0.001)
    }

    func testOnlyTextTypedOnTheEndOfTheSameRunIsCarriedForward() {
        XCTAssertNil(PixelCaretLocator.extrapolated(from: base, for: request("the end of the paragraph")), "the same text is the cached capture's business")
        XCTAssertNil(PixelCaretLocator.extrapolated(from: base, for: request("the end of the paragrap")), "a deletion")
        XCTAssertNil(PixelCaretLocator.extrapolated(from: base, for: request("The end of the paragraph and")), "an edit elsewhere")
        XCTAssertNil(PixelCaretLocator.extrapolated(from: base, for: request("the end of the paragraph\nand")), "a new paragraph")
        XCTAssertNil(PixelCaretLocator.extrapolated(from: base, for: request("the end of the paragraph and", frame: frame.offsetBy(dx: 0, dy: -24))), "another run frame (the paragraph reflowed)")
        XCTAssertNil(PixelCaretLocator.extrapolated(from: base, for: request("the end of the paragraph and", font: nil)), "no face to measure the typed text in")
        let long = "the end of the paragraph" + String(repeating: " and more", count: 8)
        XCTAssertNil(PixelCaretLocator.extrapolated(from: base, for: request(long)), "too much typed since the capture to trust the arithmetic")
    }

    /// Past the run's right edge the paragraph has wrapped: the caret is on a line the capture
    /// never saw, so a capture is needed.
    func testACaretCarriedPastTheRunsEdgeIsNotTrusted() {
        let wide = PixelCaretLocator.Request(
            focusedInputIdentityKey: 1, runFrame: frame, paragraphTextBeforeCaret: "the end of the paragraph and then the words that wrap around the edge",
            siblingLinePitch: 24, siblingLineBoxHeight: 20, spaceAdvance: 4.5, font: font
        )
        // 1000 + the advance of the 44 typed characters at 16pt (over 300pt) is past the frame's
        // right edge at 1213 plus two spaces of slack.
        XCTAssertNil(PixelCaretLocator.extrapolated(from: base, for: wide))
    }

    /// A one-line run's frame widens as the host catches up with the typing; the capture it was
    /// read in still names the same line.
    func testAWiderFrameForTheSameLineStillCarriesForward() {
        let wider = request("the end of the paragraph and", frame: CGRect(x: 608, y: 700, width: 640, height: 44))
        XCTAssertNotNil(PixelCaretLocator.extrapolated(from: base, for: wider))
    }

    func testTypedTextIsWhatFollowsTheCapturedParagraph() {
        XCTAssertEqual(PixelCaretLocator.appendedText(from: "ab", to: "abc d"), "c d")
        XCTAssertNil(PixelCaretLocator.appendedText(from: "ab", to: "ab"))
        XCTAssertNil(PixelCaretLocator.appendedText(from: "ab", to: "xbc"))
        XCTAssertNil(PixelCaretLocator.appendedText(from: "ab", to: "ab\nc"))
        XCTAssertNil(PixelCaretLocator.appendedText(from: "", to: String(repeating: "x", count: PixelCaretLocator.maximumExtrapolatedCharacters + 1)))
        XCTAssertNotNil(PixelCaretLocator.appendedText(from: "", to: String(repeating: "x", count: PixelCaretLocator.maximumExtrapolatedCharacters)))
    }
}

/// Where a one-line run is read: its own line box, widened to where its text now ends.
@MainActor
final class OneLineRunReadFrameTests: XCTestCase {
    func testTheReadFrameReachesPastTheTypedTextButNeverPastTheField() {
        let font = NSFont.systemFont(ofSize: 16)
        // The run's frame trails the typing: the host laid it out for fewer characters.
        let run = WrappedRunAnchor(
            frame: CGRect(x: 608, y: 503, width: 300, height: 20),
            paragraphTextBeforeCaret: "A short second paragraph that stays on one line and keeps",
            spansOneLine: true
        )
        let textEnd = 608 + GhostFontResolver.width(of: run.paragraphTextBeforeCaret, font: font)
        let open = OverlayController.oneLineRunReadFrame(run, font: font, fieldRight: 1512)
        XCTAssertEqual(open.minX, 608)
        XCTAssertEqual(open.minY, 503)
        XCTAssertEqual(open.height, 20)
        XCTAssertEqual(open.maxX, textEnd + OverlayController.oneLineRunReadMargin, accuracy: 0.001)
        let clamped = OverlayController.oneLineRunReadFrame(run, font: font, fieldRight: textEnd)
        XCTAssertEqual(clamped.maxX, textEnd, accuracy: 0.001, "never past the field's own edge")
    }
}
