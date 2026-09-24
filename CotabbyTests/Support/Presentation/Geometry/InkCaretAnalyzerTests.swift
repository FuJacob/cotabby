import AppKit
import XCTest
@testable import Cotabby

/// The analyzer is exercised on text rendered at known positions, so the lines it finds and the
/// ink edges it reports can be checked against what was actually drawn.
final class InkCaretAnalyzerTests: XCTestCase {
    private struct Rendered {
        let bitmap: RGBABitmap
        let lineWidths: [CGFloat]
    }

    private struct Canvas {
        let font: NSFont
        let pitch: Int
        let inset: Int
        let width: Int
        let height: Int
    }

    /// Draws `lines` of light text on a dark background, one per `canvas.pitch` rows.
    private func render(lines: [String], on canvas: Canvas) -> Rendered? {
        let (font, pitch, inset, width, height) = (canvas.font, canvas.pitch, canvas.inset, canvas.width, canvas.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.15, green: 0.15, blue: 0.16, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var widths: [CGFloat] = []
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 0.9, alpha: 1)]
        for (index, text) in lines.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            // Row 0 is the top in the analyzer; CGContext is bottom-up, so the baseline sits at
            // height - (index + 1) * pitch + descender room.
            let baseline = CGFloat(height) - CGFloat((index + 1) * pitch) + abs(font.descender) + 2
            context.textPosition = CGPoint(x: CGFloat(inset), y: baseline)
            CTLineDraw(line, context)
            widths.append(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        guard let image = context.makeImage(), let bitmap = RGBABitmap(image) else { return nil }
        return Rendered(bitmap: bitmap, lineWidths: widths)
    }

    func testFindsEachLineItsPitchAndWhereItsInkEnds() throws {
        let font = NSFont.systemFont(ofSize: 34)   // 17pt at 2x
        let rendered = try XCTUnwrap(render(
            lines: ["The quick brown fox jumps over the lazy dog and keeps going", "the second line ends here"],
            on: Canvas(font: font, pitch: 48, inset: 12, width: 1200, height: 100)
        ))
        let measurement = try XCTUnwrap(InkCaretAnalyzer.measure(rendered.bitmap))
        XCTAssertEqual(measurement.lines.count, 2)
        XCTAssertEqual(try XCTUnwrap(measurement.pitchRows), 48, accuracy: 1)
        for (line, width) in zip(measurement.lines, rendered.lineWidths) {
            // Ink ends within a couple of pixels of the typographic advance (the last glyph's side
            // bearing), and starts at the left margin.
            XCTAssertEqual(Double(line.inkRightColumn), Double(12) + Double(width), accuracy: 4)
            XCTAssertEqual(line.inkLeftColumn, 12, accuracy: 4)
            XCTAssertGreaterThanOrEqual(line.inkHeight, InkCaretAnalyzer.minimumLineHeightRows)
        }
        XCTAssertLessThan(measurement.lines[0].bottomRow, measurement.lines[1].topRow)
    }

    /// Measured in Obsidian: a pitch read from ink tops came out 41 rows instead of 48 when one
    /// line held ascenders and the next did not. Baselines do not move with the text.
    func testPitchComesFromBaselinesNotInkTops() throws {
        let font = NSFont.systemFont(ofSize: 34)
        let rendered = try XCTUnwrap(render(
            lines: ["The quick brown fox jumps over the lazy dog", "some rows worn as a sensor was worn"],
            on: Canvas(font: font, pitch: 48, inset: 12, width: 1200, height: 100)
        ))
        let measurement = try XCTUnwrap(InkCaretAnalyzer.measure(rendered.bitmap))
        XCTAssertEqual(measurement.lines.count, 2)
        // The second line has no ascender, so its ink top sits lower than the first line's.
        XCTAssertGreaterThan(measurement.lines[1].topRow - measurement.lines[0].topRow, 48 + 3)
        XCTAssertEqual(try XCTUnwrap(measurement.pitchRows), 48, accuracy: 1)
        for line in measurement.lines {
            XCTAssertGreaterThan(line.baselineRow, line.topRow)
            XCTAssertLessThanOrEqual(line.baselineRow, line.bottomRow + 1)
        }
        // Each baseline sits where the renderer put it: descender room + 2 rows above the pitch line.
        let expectedFirstBaseline = 48 - Int((abs(font.descender) + 2).rounded())
        XCTAssertEqual(measurement.lines[0].baselineRow, expectedFirstBaseline, accuracy: 1)
    }

    func testSingleLineHasNoPitch() throws {
        let rendered = try XCTUnwrap(render(
            lines: ["only one line"], on: Canvas(font: NSFont.systemFont(ofSize: 30), pitch: 44, inset: 10, width: 600, height: 50)
        ))
        let measurement = try XCTUnwrap(InkCaretAnalyzer.measure(rendered.bitmap))
        XCTAssertEqual(measurement.lines.count, 1)
        XCTAssertNil(measurement.pitchRows)
    }

    /// One line of light text on the dark ground, optionally followed by a caret bar drawn the way
    /// CodeMirror draws it: in the text colour, `bar.width` pixels wide, over the whole line box,
    /// `bar.gap` pixels after the line's advance. Returns the bitmap and the bar's columns.
    private func renderLine(
        _ text: String, bar: (gap: Int, width: Int)?, width: Int = 600, height: Int = 44, inset: Int = 12
    ) -> (bitmap: RGBABitmap, bar: ClosedRange<Int>?)? {
        let font = NSFont.systemFont(ofSize: 32)   // 16pt at 2x
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.15, green: 0.15, blue: 0.16, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: NSColor(white: 0.9, alpha: 1)]
        ))
        context.textPosition = CGPoint(x: CGFloat(inset), y: abs(font.descender) + 4)
        CTLineDraw(line, context)
        var columns: ClosedRange<Int>?
        if let bar {
            let x = inset + Int(CTLineGetTypographicBounds(line, nil, nil, nil).rounded(.up)) + bar.gap
            context.setFillColor(CGColor(gray: 0.9, alpha: 1))
            context.fill(CGRect(x: x, y: 1, width: bar.width, height: height - 2))
            columns = x...(x + bar.width - 1)
        }
        guard let image = context.makeImage(), let bitmap = RGBABitmap(image) else { return nil }
        return (bitmap, columns)
    }

    /// Measured in Obsidian (2026-09-10): the host's caret, a text-coloured bar over the whole line
    /// box right after the last glyph, was read as that glyph's ink and put the caret a point right.
    func testTheHostsCaretBarIsFoundAndKeptOutOfTheTextsEdge() throws {
        let rendered = try XCTUnwrap(renderLine("A short second p", bar: (gap: 1, width: 2)))
        let line = try XCTUnwrap(InkCaretAnalyzer.measure(rendered.bitmap)?.lines.first)
        XCTAssertEqual(line.caretBarColumns, rendered.bar)
        let barLeft = try XCTUnwrap(rendered.bar?.lowerBound)
        XCTAssertLessThan(line.textRightColumn, barLeft)
        XCTAssertGreaterThan(line.textRightColumn, barLeft - 6, "the text ends right before the caret")
    }

    /// After a trailing space the bar stands clear of the text by the space's advance.
    func testACaretBarAfterATrailingSpaceIsStillTheCaret() throws {
        let rendered = try XCTUnwrap(renderLine("A short second ", bar: (gap: 0, width: 2)))
        let line = try XCTUnwrap(InkCaretAnalyzer.measure(rendered.bitmap)?.lines.first)
        XCTAssertEqual(line.caretBarColumns, rendered.bar)
        XCTAssertLessThan(line.textRightColumn, try XCTUnwrap(rendered.bar?.lowerBound) - 4)
    }

    /// A final tall letter fills a line without descenders just as a caret would, but it stops at
    /// the baseline; with the caret off (its blink) nothing is taken for a bar.
    func testATallLastLetterIsNotACaret() throws {
        let rendered = try XCTUnwrap(renderLine("wool tall", bar: nil))
        let line = try XCTUnwrap(InkCaretAnalyzer.measure(rendered.bitmap)?.lines.first)
        XCTAssertNil(line.caretBarColumns)
        XCTAssertEqual(line.textRightColumn, line.inkRightColumn)
    }

    func testABlockWiderThanAnyCaretIsNotACaret() throws {
        let rendered = try XCTUnwrap(renderLine("A short second p", bar: (gap: 2, width: 6)))
        let line = try XCTUnwrap(InkCaretAnalyzer.measure(rendered.bitmap)?.lines.first)
        XCTAssertNil(line.caretBarColumns)
    }

    /// Dark text on a light ground at 15.336pt (2x), one line per 40 rows (Claude's composer: 14px at
    /// its 110% zoom, line-height 1.3), with an optional caret bar drawn the way Chromium draws it:
    /// in the text colour, 2px wide, from `barTopBelowFirstLine` rows under the first line's lowest ink
    /// down to the caret line's descent. The caret stands after the last line's text, or at the line
    /// start when that line is empty. Returns the bitmap, the bar's columns and the first line's
    /// lowest inked row.
    private func renderTight(
        _ lines: [String], barTopBelowFirstLine: Int?
    ) -> (bitmap: RGBABitmap, bar: ClosedRange<Int>?, firstLineBottom: Int)? {
        let font = NSFont.systemFont(ofSize: 30.672)
        let (width, height, pitch, inset) = (1400, 100, 40, 12)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let ink = NSColor(red: 0.08, green: 0.08, blue: 0.075, alpha: 1)
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let halfLeading = (CGFloat(pitch) - ascent - descent) / 2
        func baseline(_ index: Int) -> CGFloat { CGFloat(height - 10 - index * pitch) - halfLeading - ascent }
        var lastAdvance: CGFloat = 0
        for (index, text) in lines.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink]))
            context.textPosition = CGPoint(x: CGFloat(inset), y: baseline(index))
            CTLineDraw(line, context)
            lastAdvance = CTLineGetTypographicBounds(line, nil, nil, nil)
        }
        guard let firstImage = context.makeImage(), let first = RGBABitmap(firstImage) else { return nil }
        var firstLineBottom = 0
        for row in 0..<(10 + pitch) {
            for column in 0..<width where first.pixel(column: column, row: row).luminance < 0.7 {
                firstLineBottom = max(firstLineBottom, row)
            }
        }
        var columns: ClosedRange<Int>?
        if let barTopBelowFirstLine {
            let x = inset + Int(lastAdvance.rounded(.up)) + 2
            let topRow = firstLineBottom + barTopBelowFirstLine
            let bottomRow = Int((CGFloat(height) - baseline(lines.count - 1) + descent).rounded())
            context.setFillColor(ink.cgColor)
            context.fill(CGRect(x: x, y: height - bottomRow - 1, width: 2, height: bottomRow - topRow + 1))
            columns = x...(x + 1)
        }
        guard let image = context.makeImage(), let bitmap = RGBABitmap(image) else { return nil }
        return (bitmap, columns, firstLineBottom)
    }

    /// Measured 2026-09-11 in Claude's composer: under its tight line height the caret reached to
    /// within two device rows of the line above's descenders, the two lines read as one block, and
    /// after every wrap the caret was put at the end of the FIRST line. The bar is set aside while
    /// the lines are found, and is still the caret of the line it stands on.
    func testACaretBarBridgingTwoTightLinesDoesNotJoinThem() throws {
        let rendered = try XCTUnwrap(renderTight(
            ["There are still a lot of problems, a LOT of problems with positioning, going,", "keep"], barTopBelowFirstLine: 3
        ))
        let measurement = try XCTUnwrap(InkCaretAnalyzer.measure(rendered.bitmap))
        XCTAssertEqual(measurement.lines.count, 2)
        XCTAssertEqual(try XCTUnwrap(measurement.pitchRows), 40, accuracy: 1)
        let bar = try XCTUnwrap(rendered.bar)
        XCTAssertEqual(measurement.lines[1].caretBarColumns, bar)
        XCTAssertLessThan(measurement.lines[1].textRightColumn, bar.lowerBound)
        XCTAssertEqual(measurement.lines[0].bottomRow, rendered.firstLineBottom, "the first line keeps its own rows")
        XCTAssertGreaterThan(measurement.lines[0].inkRightColumn, 900, "and its own right edge")
    }

    /// A caret alone on a fresh line (after a line break) is that line's only ink, as before.
    func testACaretAloneOnAFreshLineIsThatLine() throws {
        let rendered = try XCTUnwrap(renderTight(
            ["There are still a lot of problems, a LOT of problems with positioning, going,", ""], barTopBelowFirstLine: 3
        ))
        let measurement = try XCTUnwrap(InkCaretAnalyzer.measure(rendered.bitmap))
        XCTAssertEqual(measurement.lines.count, 2)
        let bar = try XCTUnwrap(rendered.bar)
        XCTAssertEqual(measurement.lines[1].inkLeftColumn, bar.lowerBound)
        XCTAssertEqual(measurement.lines[1].inkRightColumn, bar.upperBound)
    }

    /// A stroke no taller than the text's own (a "|", an "l") is text: nothing is set aside, and with
    /// the caret hidden by its blink the lines are found exactly as before.
    func testAGlyphStrokeIsNotTakenForTheCaret() throws {
        let rendered = try XCTUnwrap(renderTight(["a path | with bars | and ll", "then the next line"], barTopBelowFirstLine: nil))
        let measurement = try XCTUnwrap(InkCaretAnalyzer.measure(rendered.bitmap))
        XCTAssertEqual(measurement.lines.count, 2)
        XCTAssertNil(measurement.lines[0].caretBarColumns)
        XCTAssertNil(measurement.lines[1].caretBarColumns)
    }

    /// The pair measured 2026-09-11 in Claude's composer (2x): a full line (rows 19-49, baseline 42)
    /// and a fresh line holding one "E" beside the caret (rows 56-93), whose first busy rows are the
    /// capital's top bar, so its baseline read 25 rows below the first line's for a 44-row pitch.
    /// Two separate lines cannot be closer than about their ink height: no pitch from that pair.
    func testALoneCapitalsTopBarGivesNoPitch() {
        let lines = [
            InkCaretAnalyzer.Line(topRow: 19, bottomRow: 49, inkLeftColumn: 12, inkRightColumn: 1343, baselineRow: 42),
            InkCaretAnalyzer.Line(topRow: 56, bottomRow: 93, inkLeftColumn: 14, inkRightColumn: 31, baselineRow: 67)
        ]
        XCTAssertNil(InkCaretAnalyzer.pitchRows(of: lines))
        let settled = [lines[0], InkCaretAnalyzer.Line(topRow: 61, bottomRow: 93, inkLeftColumn: 13, inkRightColumn: 1251, baselineRow: 86)]
        XCTAssertEqual(try XCTUnwrap(InkCaretAnalyzer.pitchRows(of: settled)), 44, accuracy: 0.5)
    }

    /// Rendered: a capital alone on the caret's fresh line never yields a pitch shorter than the
    /// lines' own ink (a true one, 40 rows here, is still fine).
    func testACapitalAloneOnAFreshLineIsNoShortPitch() throws {
        for capital in ["E", "T", "F"] {
            let rendered = try XCTUnwrap(renderTight(
                ["There are still a lot of problems, a LOT of problems with positioning, going,", capital], barTopBelowFirstLine: 3
            ))
            let measurement = try XCTUnwrap(InkCaretAnalyzer.measure(rendered.bitmap))
            XCTAssertEqual(measurement.lines.count, 2, capital)
            if let pitch = measurement.pitchRows {
                XCTAssertEqual(pitch, 40, accuracy: 1, capital)
            }
        }
    }

    func testBlankCaptureMeasuresNothing() throws {
        let rendered = try XCTUnwrap(render(
            lines: [], on: Canvas(font: NSFont.systemFont(ofSize: 30), pitch: 44, inset: 10, width: 300, height: 40)
        ))
        XCTAssertNil(InkCaretAnalyzer.measure(rendered.bitmap))
    }

    /// Claude's Code composer (2026-09-11, 2x): each row's ink beside the caret after "Should". Rows
    /// 11-12 are the S's top curve and the ascender tops, 13-14 the stems between them and the
    /// lowercase letters, 15-31 the letters (the busiest row, 60, their bottom curves), the rest the
    /// caret bar alone. The first busy run was the top curve: the baseline read 5.5pt into a 19pt
    /// caret box for the true 15.0, and the ghost was drawn nine points high.
    func testTheLetterBodiesAreNotACapitalsTopCurve() {
        let should = [0, 0, 2, 2, 2, 2, 2, 2, 2, 12, 19, 21, 23, 19, 17, 39, 45, 53, 44, 44, 41, 40, 39, 34, 36, 39, 40, 41, 41,
                      60, 54, 45, 6, 2, 2, 2, 2, 2, 2, 2, 0, 0]
        XCTAssertEqual(InkCaretAnalyzer.bodyRows(in: should, threshold: InkCaretAnalyzer.bodyThreshold * 60), 15...31)
    }

    /// Chrome's address bar (2026-09-11): "is g". The letters end at row 45; the "g"'s bowl passes the
    /// threshold again at rows 48-50, under two thin rows, and is no part of them.
    func testADescendersBowlIsNotPartOfTheLetterBodies() {
        let isG = [Int](repeating: 0, count: 18) + [2, 2, 2, 2, 2, 2, 2, 5, 7, 5, 3, 2, 5, 22, 27, 27, 20, 16, 17, 20, 21, 19, 16, 18,
                                                     25, 27, 25, 16, 6, 9, 14, 13, 10, 2]
        XCTAssertEqual(InkCaretAnalyzer.bodyRows(in: isG, threshold: InkCaretAnalyzer.bodyThreshold * 27), 31...45)
    }

    /// A lone capital has no letter bodies: its first bar stands, as before, whether a lower bar is as
    /// thick (an "E") or a row thicker (an "F"'s middle bar, which is no baseline).
    func testALoneCapitalKeepsItsFirstBar() {
        let e = [2, 2, 20, 20, 20, 6, 6, 6, 6, 6, 6, 6, 20, 20, 20, 6, 6, 6, 6, 6, 6, 6, 20, 20, 20, 2, 2, 2]
        XCTAssertEqual(InkCaretAnalyzer.bodyRows(in: e, threshold: 7), 2...4)
        let f = [2, 2, 20, 20, 20, 6, 6, 6, 6, 6, 6, 20, 20, 20, 20, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 2, 2, 2]
        XCTAssertEqual(InkCaretAnalyzer.bodyRows(in: f, threshold: 7), 2...4)
    }
}
