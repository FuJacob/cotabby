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

    func testWrapDeclinedWithoutLinePitch() {
        let text = " alpha bravo charlie delta echo foxtrot golf hotel"
        XCTAssertNil(GhostTextLayout.make(input(text: text, anchor: CGPoint(x: 300, y: 200), pitch: nil)))
    }

    func testWrapDeclinedWhenTextFollowsTheCaret() {
        let text = " alpha bravo charlie delta echo foxtrot golf hotel"
        XCTAssertNil(GhostTextLayout.make(input(text: text, anchor: CGPoint(x: 300, y: 200), allowsMultipleRows: false)))
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

    func testHardNewlineInSingleRowModeDeclines() {
        XCTAssertNil(GhostTextLayout.make(input(text: " one\ntwo", pitch: nil)))
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
}
