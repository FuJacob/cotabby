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
        keycapWidth: CGFloat = 0,
        paintsRowBands: Bool = false,
        coversCaretRow: Bool = false,
        containerFrame: CGRect? = nil
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
            keycapWidth: keycapWidth,
            paintsRowBands: paintsRowBands,
            coversCaretRow: coversCaretRow,
            containerFrame: containerFrame
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

    func testTextAfterTheCaretWithoutABandKeepsTheGhostToOneRow() throws {
        let text = " alpha bravo charlie delta echo foxtrot golf hotel"
        let layout = try XCTUnwrap(GhostTextLayout.make(input(text: text, anchor: CGPoint(x: 300, y: 200), allowsMultipleRows: false)))
        XCTAssertEqual(layout.rows.count, 1)
        XCTAssertTrue(layout.isTruncated)
        XCTAssertTrue(layout.rowBands.isEmpty)
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

    // MARK: - Bands

    func testContinuationRowsGetFullWidthBandsThatTileOneLinePitchApart() throws {
        // Pitch 20 for a 16pt box: 2pt of leading above and below each box. Row 1's band starts
        // 2pt above its box and ends at its box bottom (it is the last row); row 0 has no band
        // because nothing follows the caret on its line.
        let text = " alpha bravo charlie delta"
        let layout = try XCTUnwrap(
            GhostTextLayout.make(input(text: text, anchor: CGPoint(x: 300, y: 200), pitch: 20, paintsRowBands: true))
        )
        XCTAssertEqual(layout.rows.count, 2)
        XCTAssertEqual(layout.rowBands.count, 1)
        let band = layout.rowBands[0]
        XCTAssertFalse(band.isCaretRow)
        let rowTop = layout.rows[1].baselineY + 13
        XCTAssertEqual(band.rect.minX, 100)
        XCTAssertEqual(band.rect.maxX, 400)
        XCTAssertEqual(band.rect.maxY, rowTop + 2, accuracy: 0.001)
        XCTAssertEqual(band.rect.minY, rowTop - 16, accuracy: 0.001)
        XCTAssertTrue(layout.contentBounds.contains(band.rect))
    }

    func testThreeRowsTileWithoutSeams() throws {
        let text = " alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar"
        let layout = try XCTUnwrap(GhostTextLayout.make(
            input(text: text, anchor: CGPoint(x: 280, y: 200), pitch: 20, band: 100...300, paintsRowBands: true, coversCaretRow: true)
        ))
        XCTAssertGreaterThanOrEqual(layout.rows.count, 3)
        XCTAssertEqual(layout.rowBands.count, layout.rows.count)
        for (upper, lower) in zip(layout.rowBands, layout.rowBands.dropFirst()) {
            XCTAssertEqual(upper.rect.minY, lower.rect.maxY, accuracy: 0.001, "bands must meet edge to edge")
        }
        XCTAssertEqual(layout.rowBands[0].rect.maxY, 200, "the caret row's band never rises above the caret box")
    }

    func testCaretRowBandRunsFromThePenToTheBandEdgeWhenTextFollowsTheCaret() throws {
        let layout = try XCTUnwrap(
            GhostTextLayout.make(input(text: " world", anchor: CGPoint(x: 150, y: 200), paintsRowBands: true, coversCaretRow: true))
        )
        XCTAssertEqual(layout.rowBands.count, 1)
        let band = layout.rowBands[0]
        XCTAssertTrue(band.isCaretRow)
        XCTAssertEqual(band.rect, CGRect(x: 150, y: 184, width: 250, height: 16))
    }

    func testBandsAreClippedToTheContainer() throws {
        let text = " alpha bravo charlie delta echo foxtrot golf hotel"
        let container = CGRect(x: 90, y: 175, width: 320, height: 40)
        let layout = try XCTUnwrap(GhostTextLayout.make(
            input(text: text, anchor: CGPoint(x: 300, y: 200), pitch: 20, paintsRowBands: true, containerFrame: container)
        ))
        XCTAssertEqual(layout.rowBands.count, 1)
        XCTAssertEqual(layout.rowBands[0].rect.minY, 175, accuracy: 0.001)
    }

    func testACaretRowNothingFitsOnKeepsItsPlaceAndItsBand() throws {
        // The caret sits 5pt from the band's right edge and the text has no leading space to hang
        // there, so it starts on the next line; row 0 stays at the caret (empty) so its band still
        // hides the host text after the caret.
        let layout = try XCTUnwrap(GhostTextLayout.make(
            input(text: "alpha bravo", anchor: CGPoint(x: 395, y: 200), pitch: 20, paintsRowBands: true, coversCaretRow: true)
        ))
        XCTAssertEqual(layout.rows.count, 2)
        XCTAssertEqual(layout.rows[0].text, "")
        XCTAssertEqual(layout.rows[0].penX, 395)
        XCTAssertEqual(layout.rows[0].baselineY, 187)
        XCTAssertEqual(layout.rows[1].text, "alpha bravo")
        XCTAssertEqual(layout.rows[1].baselineY, 167)
        XCTAssertEqual(layout.rowBands.count, 2)
        XCTAssertEqual(layout.rowBands[0].rect, CGRect(x: 395, y: 182, width: 5, height: 18))
        XCTAssertEqual(layout.rowBands[1].rect, CGRect(x: 100, y: 164, width: 300, height: 18))
        XCTAssertEqual(layout.remainingText, "alpha bravo")
    }

    func testNoBandsUnlessAsked() throws {
        let text = " alpha bravo charlie delta echo foxtrot golf hotel"
        let layout = try XCTUnwrap(GhostTextLayout.make(input(text: text, anchor: CGPoint(x: 300, y: 200), coversCaretRow: true)))
        XCTAssertTrue(layout.rowBands.isEmpty)
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
