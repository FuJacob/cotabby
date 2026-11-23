import XCTest
@testable import Cotabby

/// Which text-marker line boxes the probe believes (see `HostTextMetricsProbe.isCaretLine`).
@MainActor
final class HostTextMetricsProbeCaretLineTests: XCTestCase {
    private let field = CGRect(x: 88, y: 327, width: 546, height: 257)

    func testTheCaretsOwnLineIsBelieved() {
        let line = CGRect(x: 101, y: 540, width: 520, height: 29)
        let caret = CGRect(x: 400, y: 544, width: 1, height: 21)
        XCTAssertTrue(HostTextMetricsProbe.isCaretLine(line, caret: caret, anchor: field, caretHeight: 21))
    }

    /// Measured 2026-09-10 in Chrome: a box 696pt wide and 88pt tall above a 546pt field.
    func testABoxOutsideTheFieldOrTallerThanALineIsNot() {
        let caret = CGRect(x: 400, y: 544, width: 1, height: 21)
        XCTAssertFalse(HostTextMetricsProbe.isCaretLine(
            CGRect(x: 44, y: 585.5, width: 696, height: 88), caret: caret, anchor: field, caretHeight: 21
        ))
        XCTAssertFalse(HostTextMetricsProbe.isCaretLine(
            CGRect(x: 101, y: 400, width: 520, height: 60), caret: nil, anchor: field, caretHeight: 21
        ), "three lines tall is no line")
        XCTAssertFalse(HostTextMetricsProbe.isCaretLine(
            CGRect(x: 101, y: 400, width: 520, height: 29), caret: caret, anchor: field, caretHeight: 21
        ), "a line that does not hold the caret is another line")
    }
}

/// Marker lines from glyph boxes, with Claude's composer as measured on 2026-09-11 (Cocoa rects).
@MainActor
final class HostTextMetricsProbeMarkerLineTests: XCTestCase {
    private let composer = CGRect(x: 84, y: 862, width: 801, height: 48)

    /// The line range's box was the paragraph's padded block: x 84 for text at 95, 33pt tall.
    func testTheLineStartsAtItsFirstGlyphNotAtItsPaddedBox() throws {
        let padded = CGRect(x: 84, y: 866, width: 731, height: 33)
        let glyph = CGRect(x: 95, y: 871, width: 8, height: 19)
        let caret = CGRect(x: 813, y: 871, width: 0, height: 19)
        let line = try XCTUnwrap(HostTextMetricsProbe.markerLine(
            .init(lineBox: padded, firstCharacter: glyph),
            caret: caret, anchor: composer, caretHeight: 19
        ))
        XCTAssertEqual(line.rect.minX, 95)
        XCTAssertEqual(line.rect.height, 19)
        XCTAssertNil(line.pitch)
    }

    /// A wrapped paragraph's box spans both lines and fails the one-line check; the glyphs of the
    /// two lines still measure the pitch.
    func testTheGlyphsOfTwoLinesMeasureThePitchWhereTheBoxesSpanBoth() throws {
        let field = CGRect(x: 84, y: 842, width: 801, height: 68)
        let paragraph = CGRect(x: 84, y: 846, width: 790, height: 56)
        let lineTwo = CGRect(x: 95, y: 851, width: 8, height: 19)
        let lineOne = CGRect(x: 95, y: 874, width: 8, height: 19)
        let caret = CGRect(x: 300, y: 851, width: 0, height: 19)
        let line = try XCTUnwrap(HostTextMetricsProbe.markerLine(
            .init(lineBox: paragraph, firstCharacter: lineTwo, previousLineBox: paragraph, previousFirstCharacter: lineOne),
            caret: caret, anchor: field, caretHeight: 19
        ))
        XCTAssertEqual(line.rect.minX, 95)
        XCTAssertEqual(try XCTUnwrap(line.pitch), 23, accuracy: 0.001)
    }

    /// Where the host's line boxes are glyph lines (a ProseMirror-style page), nothing changes.
    func testGlyphLineBoxesMeasureTheSame() throws {
        let field = CGRect(x: 100, y: 747, width: 863, height: 77)
        let lineTwo = CGRect(x: 113, y: 767, width: 93, height: 20)
        let lineOne = CGRect(x: 113, y: 791, width: 700, height: 19)
        let line = try XCTUnwrap(HostTextMetricsProbe.markerLine(
            .init(
                lineBox: lineTwo, firstCharacter: CGRect(x: 113, y: 767, width: 9, height: 20),
                previousLineBox: lineOne, previousFirstCharacter: CGRect(x: 113, y: 791, width: 9, height: 19)
            ),
            caret: CGRect(x: 206, y: 767, width: 0, height: 20), anchor: field, caretHeight: 20
        ))
        XCTAssertEqual(line.rect.minX, 113)
        XCTAssertEqual(try XCTUnwrap(line.pitch), 23.5, accuracy: 0.001)
    }

    /// A ProseMirror-style paragraph (a <p> per paragraph, no padding) frames one line box: in the
    /// ProseMirror-style page in Chrome (2026-09-11) the caret's glyph box was 17pt and its paragraph 21pt,
    /// 14px at line-height 1.5, starting where the text does. In a browser a one-line paragraph takes
    /// that for its pitch before any second line exists; elsewhere nothing changes.
    func testAOneLineParagraphsBoxIsItsPitchInABrowser() throws {
        let field = CGRect(x: 96, y: 700, width: 784, height: 70)
        let glyph = CGRect(x: 108, y: 740, width: 9, height: 17)
        let paragraph = CGRect(x: 108, y: 738, width: 760, height: 21)
        func line(browser: Bool) -> HostTextMetricsProbe.MarkerLine? {
            HostTextMetricsProbe.markerLine(
                .init(lineBox: CGRect(x: 108, y: 740, width: 73, height: 17), firstCharacter: glyph, paragraph: paragraph),
                caret: CGRect(x: 181, y: 740, width: 0, height: 17), anchor: field, caretHeight: 17,
                allowsParagraphPitch: browser
            )
        }
        XCTAssertEqual(try XCTUnwrap(line(browser: true)?.pitch), 21, accuracy: 0.001)
        XCTAssertEqual(line(browser: true)?.pitchFromParagraph, true)
        XCTAssertNotNil(line(browser: false))
        XCTAssertNil(line(browser: false)?.pitch)
    }

    /// A block padded beside its text, or two lines tall, is not one line's box.
    func testAPaddedOrTwoLineParagraphIsNoLineBox() {
        let glyph = CGRect(x: 95, y: 871, width: 8, height: 19)
        XCTAssertNil(HostTextMetricsProbe.paragraphLinePitch(paragraph: CGRect(x: 84, y: 866, width: 731, height: 33), firstCharacter: glyph))
        XCTAssertNil(HostTextMetricsProbe.paragraphLinePitch(paragraph: CGRect(x: 95, y: 850, width: 731, height: 46), firstCharacter: glyph))
        XCTAssertEqual(HostTextMetricsProbe.paragraphLinePitch(paragraph: CGRect(x: 95, y: 869, width: 731, height: 23), firstCharacter: glyph), 23)
    }

    /// An empty line has no glyph: its box stands, and a frame-sized box is still no line.
    func testAnEmptyLineKeepsItsBoxAndAFrameSizedBoxIsDropped() {
        let empty = CGRect(x: 95, y: 868, width: 785, height: 20)
        XCTAssertEqual(HostTextMetricsProbe.markerLine(
            .init(lineBox: empty),
            caret: CGRect(x: 95, y: 868, width: 0, height: 20), anchor: composer, caretHeight: 20
        )?.rect.minX, 95)
        XCTAssertNil(HostTextMetricsProbe.markerLine(
            .init(lineBox: composer),
            caret: CGRect(x: 95, y: 868, width: 0, height: 20), anchor: composer, caretHeight: 20
        ))
    }

    /// Gmail's compose body in Chrome (2026-09-11): the caret line's range started at x 804, then
    /// 743, on a line whose text starts at 393 (15pt glyph boxes, a line 15pt above). The ranges
    /// before such a start on the same glyph row are earlier parts of the line; the line above, and
    /// text in a column further left, are not.
    func testALineRangeStartingPartwayAlongItsLineHasEarlierFragments() {
        let first = CGRect(x: 804, y: 220, width: 7, height: 15)
        XCTAssertTrue(AXHelper.isEarlierFragment(CGRect(x: 743, y: 220, width: 61, height: 15), ofLineStartingAt: first))
        XCTAssertTrue(AXHelper.isEarlierFragment(
            CGRect(x: 393, y: 220, width: 350, height: 15), ofLineStartingAt: CGRect(x: 743, y: 220, width: 8, height: 15)
        ))
        XCTAssertFalse(AXHelper.isEarlierFragment(CGRect(x: 393, y: 205, width: 1000, height: 15), ofLineStartingAt: first),
                       "the line above")
        XCTAssertFalse(AXHelper.isEarlierFragment(CGRect(x: 100, y: 220, width: 200, height: 15), ofLineStartingAt: first),
                       "a column further left")
        XCTAssertFalse(AXHelper.isEarlierFragment(CGRect(x: 393, y: 205, width: 411, height: 45), ofLineStartingAt: first),
                       "a block three lines tall")
    }
}
