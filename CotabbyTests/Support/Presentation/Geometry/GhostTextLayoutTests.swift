import AppKit
import CoreText
import XCTest
@testable import Cotabby

final class GhostTextLayoutTests: XCTestCase {
    private let menlo = NSFont(name: "Menlo-Regular", size: 14)!

    private func input(
        text: String,
        consumed: Int = 0,
        anchor: CGPoint = CGPoint(x: 100, y: 200),
        pitch: CGFloat? = 16,
        band: ClosedRange<CGFloat>? = 100...400,
        allowsMultipleRows: Bool = true,
        keycapWidth: CGFloat = 0
    ) -> GhostTextLayout.Input {
        GhostTextLayout.Input(
            fullText: text,
            consumedUTF16: consumed,
            font: menlo,
            anchorTopLeft: anchor,
            boxHeight: 16,
            baselineOffsetFromTop: 13,
            linePitch: pitch,
            wrapBand: band,
            allowsMultipleRows: allowsMultipleRows,
            keycapWidth: keycapWidth
        )
    }

    private func width(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: menlo]).width
    }

    func testSingleRowStartsAtTheCaretWithNoGap() throws {
        let layout = try XCTUnwrap(GhostTextLayout.make(input(text: " world")))
        XCTAssertEqual(layout.rows.count, 1)
        let row = layout.rows[0]
        XCTAssertEqual(row.text, " world")
        XCTAssertEqual(row.penX, 100)
        XCTAssertEqual(row.baselineY, 200 - 13)
        XCTAssertEqual(row.width, width(" world"), accuracy: 0.01)
        XCTAssertNil(layout.keycapFrame)
    }

    func testConsumedPrefixKeepsRemainingGlyphsOnTheSamePixels() throws {
        let full = try XCTUnwrap(GhostTextLayout.make(input(text: " world and more")))
        let advanced = try XCTUnwrap(GhostTextLayout.make(input(text: " world and more", consumed: 6)))
        XCTAssertEqual(advanced.rows[0].text, " and more")
        // The remaining text's pen is exactly where CoreText places index 6 in the full line.
        let expectedPen = full.rows[0].penX + width(" world")
        XCTAssertEqual(advanced.rows[0].penX, expectedPen, accuracy: 0.01)
        XCTAssertEqual(advanced.rows[0].baselineY, full.rows[0].baselineY)
    }

    func testWrapsOntoTheBandLeftEdgeOneLinePitchDown() throws {
        let text = " alpha bravo charlie delta echo foxtrot golf hotel"
        let layout = try XCTUnwrap(GhostTextLayout.make(input(text: text, anchor: CGPoint(x: 300, y: 200), band: 100...400)))
        XCTAssertGreaterThanOrEqual(layout.rows.count, 2)
        XCTAssertEqual(layout.rows[0].penX, 300)
        XCTAssertEqual(layout.rows[1].penX, 100)
        XCTAssertEqual(layout.rows[1].baselineY, layout.rows[0].baselineY - 16)
        XCTAssertEqual(layout.remainingText, text)
        XCTAssertFalse(layout.rows[1].text.hasPrefix(" "), "Wrapped rows start at a word, not a hanging space")
    }

    func testWithoutLinePitchTheHeadThatFitsIsShown() throws {
        // No second row can be placed, so the single row shows as many whole words as fit before the
        // band's right edge (110pt of Menlo 14: " alpha bravo" is 12 glyphs at 8.43pt = 101pt).
        let text = " alpha bravo charlie delta echo foxtrot golf hotel"
        let layout = try XCTUnwrap(GhostTextLayout.make(input(text: text, anchor: CGPoint(x: 290, y: 200), pitch: nil)))
        XCTAssertEqual(layout.rows.count, 1)
        XCTAssertEqual(layout.rows[0].text, " alpha bravo")
        XCTAssertTrue(layout.isTruncated)
        XCTAssertLessThanOrEqual(layout.rows[0].penX + layout.rows[0].width, 400)
    }

    func testTextBelowTheCaretKeepsTheGhostToOneRow() throws {
        // The host's own lines follow the caret's: a second row would paint over them, so only the
        // head that fits the caret row is shown and the rest is revealed as it is accepted.
        let text = " alpha bravo charlie delta echo foxtrot golf hotel"
        let layout = try XCTUnwrap(GhostTextLayout.make(input(text: text, anchor: CGPoint(x: 300, y: 200), allowsMultipleRows: false)))
        XCTAssertEqual(layout.rows.count, 1)
        XCTAssertTrue(layout.isTruncated)
    }

    func testNothingFittingOnTheOnlyRowDeclines() {
        XCTAssertNil(GhostTextLayout.make(input(text: " extraordinary", anchor: CGPoint(x: 380, y: 200), pitch: nil)))
    }

    func testTruncatedHeadDropsTheKeycapWhenThePillIsWhatCutsItShort() throws {
        // " alpha bravo" fits in 110pt only without the 30pt pill; the longer head wins over the hint.
        let text = " alpha bravo charlie delta echo foxtrot golf hotel"
        let layout = try XCTUnwrap(
            GhostTextLayout.make(input(text: text, anchor: CGPoint(x: 290, y: 200), pitch: nil, keycapWidth: 30))
        )
        XCTAssertEqual(layout.rows[0].text, " alpha bravo")
        XCTAssertNil(layout.keycapFrame)
    }

    func testFirstWordTooWideForFirstRowWrapsLikeTheHost() throws {
        // The host keeps the boundary space on the caret's line and wraps the word, so the ghost does too.
        let layout = try XCTUnwrap(GhostTextLayout.make(input(text: " extraordinary", anchor: CGPoint(x: 380, y: 200), band: 100...400)))
        XCTAssertEqual(layout.rows.count, 2)
        XCTAssertEqual(layout.rows[0].text, " ")
        XCTAssertEqual(layout.rows[0].penX, 380)
        XCTAssertEqual(layout.rows[1].text, "extraordinary")
        XCTAssertEqual(layout.rows[1].penX, 100)
        XCTAssertEqual(layout.rows[1].baselineY, 200 - 13 - 16)
    }

    func testKeycapSitsAfterTheLastRow() throws {
        let layout = try XCTUnwrap(GhostTextLayout.make(input(text: " world", keycapWidth: 30)))
        let keycap = try XCTUnwrap(layout.keycapFrame)
        let row = layout.rows[0]
        XCTAssertEqual(keycap.minX, row.penX + row.width + GhostTextLayout.keycapGap, accuracy: 0.01)
        XCTAssertEqual(keycap.width, 30)
        XCTAssertEqual(keycap.midY, 200 - 8, accuracy: 0.01)
        XCTAssertTrue(layout.contentBounds.contains(keycap))
    }

    func testFullyConsumedTextHasNoLayout() {
        XCTAssertNil(GhostTextLayout.make(input(text: " world", consumed: 6)))
    }

    func testHardNewlineInSingleRowModeShowsTheFirstLineOnly() throws {
        let layout = try XCTUnwrap(GhostTextLayout.make(input(text: " one\ntwo", pitch: nil)))
        XCTAssertEqual(layout.rows.count, 1)
        XCTAssertEqual(layout.rows[0].text, " one")
        XCTAssertTrue(layout.isTruncated)
    }

    func testHardNewlineAtTheCaretInSingleRowModeDeclines() {
        XCTAssertNil(GhostTextLayout.make(input(text: "\ntwo", pitch: nil)))
    }

    // MARK: - Wrapping at the caret

    func testACaretRowNothingFitsOnKeepsItsPlace() throws {
        // The caret sits 5pt from the band's right edge and the text has no leading space to hang
        // there, so it starts on the next line exactly where the host would wrap it; row 0 stays at
        // the caret (empty) so row indices stay one per visual line.
        let layout = try XCTUnwrap(GhostTextLayout.make(
            input(text: "alpha bravo", anchor: CGPoint(x: 395, y: 200), pitch: 20)
        ))
        XCTAssertEqual(layout.rows.count, 2)
        XCTAssertEqual(layout.rows[0].text, "")
        XCTAssertEqual(layout.rows[0].penX, 395)
        XCTAssertEqual(layout.rows[0].baselineY, 187)
        XCTAssertEqual(layout.rows[1].text, "alpha bravo")
        XCTAssertEqual(layout.rows[1].baselineY, 167)
        XCTAssertEqual(layout.remainingText, "alpha bravo")
    }

    func testRightToLeftRowEndsAtTheCaret() throws {
        var rtl = input(text: "שלום עולם")
        rtl = GhostTextLayout.Input(
            fullText: rtl.fullText, consumedUTF16: 0, font: menlo, anchorTopLeft: CGPoint(x: 300, y: 200),
            boxHeight: 16, baselineOffsetFromTop: 13, linePitch: nil, wrapBand: nil, isRightToLeft: true
        )
        let layout = try XCTUnwrap(GhostTextLayout.make(rtl))
        XCTAssertEqual(layout.rows.count, 1)
        XCTAssertEqual(layout.rows[0].penX + layout.rows[0].width, 300, accuracy: 0.01)
    }

    /// VS Code's Search field: 199pt wide, the text fits after the caret but the Tab pill does not, and
    /// a single-line field cannot wrap. The ghost is shown without its hint rather than declined.
    func testNarrowSingleRowFieldDropsTheKeycapInsteadOfDeclining() {
        let font = NSFont.systemFont(ofSize: 13)
        let layout = GhostTextLayout.make(
            GhostTextLayout.Input(
                fullText: " jumps",
                consumedUTF16: 0,
                font: font,
                anchorTopLeft: CGPoint(x: 198, y: 856),
                boxHeight: 15,
                baselineOffsetFromTop: 12,
                linePitch: nil,
                wrapBand: 73...264,
                isRightToLeft: false,
                allowsMultipleRows: true,
                keycapWidth: 30
            )
        )
        XCTAssertNotNil(layout)
        XCTAssertNil(layout?.keycapFrame)
        XCTAssertEqual(layout?.rows.count, 1)
        XCTAssertEqual(layout?.remainingText, " jumps")
    }
}
