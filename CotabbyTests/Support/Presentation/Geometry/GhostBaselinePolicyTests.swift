import AppKit
import XCTest
@testable import Cotabby

/// Every expected value below was measured from a live host with the AX probe before the policy was
/// written: TextEdit's line boxes and TextKit's own baseline offsets for the native cases, Chrome's
/// character/caret boxes for the web cases.
final class GhostBaselinePolicyTests: XCTestCase {
    private func font(_ name: String, _ size: CGFloat) -> NSFont {
        if name == "system" { return NSFont.systemFont(ofSize: size) }
        guard let font = NSFont(name: name, size: size) else {
            XCTFail("Font \(name) unavailable")
            return NSFont.systemFont(ofSize: size)
        }
        return font
    }

    func testTextKitUsesLayoutManagerBaselineNotCentering() {
        // TextEdit, Menlo 14: 16pt line fragment, baseline 13pt below its top.
        XCTAssertEqual(GhostBaselinePolicy.baselineOffsetFromTop(font: font("Menlo-Regular", 14), boxHeight: 16, renderer: .textKit), 13)
        // TextEdit, Helvetica 12: 14pt fragment, baseline 11pt. Centering the glyph box would give 10.24.
        XCTAssertEqual(GhostBaselinePolicy.baselineOffsetFromTop(font: font("Helvetica", 12), boxHeight: 14, renderer: .textKit), 11)
        XCTAssertEqual(GhostBaselinePolicy.baselineOffsetFromTop(font: font("Georgia", 18), boxHeight: 21, renderer: .textKit), 17)
        XCTAssertEqual(GhostBaselinePolicy.baselineOffsetFromTop(font: font("system", 15), boxHeight: 18, renderer: .textKit), 15)
    }

    func testTextKitTallerBoxKeepsDescentPortionAndMovesBaselineDown() {
        // A paragraph style that raised the minimum line height adds space above the glyphs.
        let offset = GhostBaselinePolicy.baselineOffsetFromTop(font: font("Menlo-Regular", 14), boxHeight: 24, renderer: .textKit)
        XCTAssertEqual(offset, 24 - (16 - 13))
    }

    func testTextKitBoxWithinOnePointOfDefaultUsesDefaultBaseline() {
        XCTAssertEqual(GhostBaselinePolicy.baselineOffsetFromTop(font: font("Menlo-Regular", 14), boxHeight: 16.5, renderer: .textKit), 13)
    }

    func testWebEngineContentAreaBoxUsesRoundedAscent() {
        // Chrome contenteditable, Georgia 18px: caret box 21 = 17 + 4.
        XCTAssertEqual(GhostBaselinePolicy.baselineOffsetFromTop(font: font("Georgia", 18), boxHeight: 21, renderer: .webEngine), 17)
        // Chrome textarea, Menlo 13px: box 15 = 12 + 3.
        XCTAssertEqual(GhostBaselinePolicy.baselineOffsetFromTop(font: font("Menlo-Regular", 13), boxHeight: 15, renderer: .webEngine), 12)
    }

    func testWebEngineRecoversBlinkRoundingFromMeasuredBox() {
        // Chrome contenteditable, system font 15px: box 17 = 14 + 3 even though the ascent (14.502)
        // would naively round up to 15.
        XCTAssertEqual(GhostBaselinePolicy.baselineOffsetFromTop(font: font("system", 15), boxHeight: 17, renderer: .webEngine), 14)
    }

    func testWebEngineAppliesTheLegacyHelveticaAscentAdjustment() {
        // Chrome <input>, Helvetica 16px: box 18 = (12 + floor(16 · 0.15)) + 4; measured text baseline
        // 14.5pt below the AX box top, i.e. 14 plus the host's own half-pixel line position.
        XCTAssertEqual(GhostBaselinePolicy.baselineOffsetFromTop(font: font("Helvetica", 16), boxHeight: 18, renderer: .webEngine), 14)
        // Same family in a taller line box: the adjusted 18pt content area is centered.
        XCTAssertEqual(GhostBaselinePolicy.baselineOffsetFromTop(font: font("Helvetica", 16), boxHeight: 24, renderer: .webEngine), 17)
        // Families outside the engines' list are untouched (Helvetica Neue is not Helvetica).
        XCTAssertEqual(GhostBaselinePolicy.baselineOffsetFromTop(font: font("HelveticaNeue", 16), boxHeight: 19, renderer: .webEngine), 15)
    }

    func testWebEngineLineBoxCentersRoundedContentArea() {
        // A loose CSS line-height: Georgia 18px in a 29px line box.
        XCTAssertEqual(GhostBaselinePolicy.baselineOffsetFromTop(font: font("Georgia", 18), boxHeight: 29, renderer: .webEngine), 21)
    }
}
