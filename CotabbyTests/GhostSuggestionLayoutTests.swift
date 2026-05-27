import CoreGraphics
import XCTest
@testable import Cotabby

final class GhostSuggestionLayoutTests: XCTestCase {

    // MARK: - Single-line layout

    func test_make_singleLineLayoutWhenTextFitsFirstLineBudget() {
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 10, y: 80, width: 2, height: 18),
            inputFrameRect: CGRect(x: 0, y: 70, width: 400, height: 30),
            observedCharWidth: 7
        )

        let layout = GhostSuggestionLayout.make(
            text: " hi",
            geometry: geometry,
            fontSize: 14,
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 300)
        )

        XCTAssertEqual(layout.lines.count, 1)
        XCTAssertEqual(layout.lines.first?.showsKeycap, true)
        XCTAssertEqual(layout.topLineCenterOffsetFromCaret, 0)
    }

    // MARK: - Multi-line layout

    func test_make_keycapAppearsOnlyOnLastLine() {
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 10, y: 80, width: 2, height: 18),
            inputFrameRect: CGRect(x: 0, y: 70, width: 200, height: 30),
            observedCharWidth: 7
        )

        let layout = GhostSuggestionLayout.make(
            text: " alpha beta gamma delta epsilon zeta eta theta iota",
            geometry: geometry,
            fontSize: 14,
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 300)
        )

        XCTAssertGreaterThan(layout.lines.count, 1, "Should wrap to multiple lines")
        for line in layout.lines.dropLast() {
            XCTAssertFalse(line.showsKeycap, "Non-last lines should not show keycap")
        }
        XCTAssertEqual(layout.lines.last?.showsKeycap, true)
    }

    // MARK: - Acceptance hint suppression

    func test_make_hidesKeycapOnEveryLineWhenAcceptanceHintDisabled() {
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 10, y: 80, width: 2, height: 18),
            inputFrameRect: CGRect(x: 0, y: 70, width: 200, height: 30),
            observedCharWidth: 7
        )

        let layout = GhostSuggestionLayout.make(
            text: " alpha beta gamma delta epsilon zeta eta theta iota",
            geometry: geometry,
            fontSize: 14,
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 300),
            showsAcceptanceHint: false
        )

        XCTAssertGreaterThan(layout.lines.count, 1, "Should still wrap to multiple lines")
        for line in layout.lines {
            XCTAssertFalse(line.showsKeycap, "No line should show a keycap when the hint is disabled")
        }
    }

    func test_make_reclaimsKeycapWidthForTextWhenAcceptanceHintDisabled() {
        // Text width (44 chars * 10pt = 440) is tuned to sit between the first-line budget with the
        // keycap reserved (492 - 28 - 36 = 428) and without it (492 - 28 = 464). So the same text
        // overflows and wraps while the hint is shown, but fits on a single line once hiding the
        // hint hands its reserved width back to the text.
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 20, y: 80, width: 2, height: 18),
            inputFrameRect: CGRect(x: 0, y: 70, width: 500, height: 30),
            observedCharWidth: 10
        )
        let text = "aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii"
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 600)

        let withHint = GhostSuggestionLayout.make(
            text: text,
            geometry: geometry,
            fontSize: 14,
            visibleFrame: visibleFrame,
            showsAcceptanceHint: true
        )
        let withoutHint = GhostSuggestionLayout.make(
            text: text,
            geometry: geometry,
            fontSize: 14,
            visibleFrame: visibleFrame,
            showsAcceptanceHint: false
        )

        XCTAssertGreaterThan(withHint.lines.count, 1, "Keycap reservation should force a wrap here")
        XCTAssertEqual(withoutHint.lines.count, 1, "Reclaimed keycap width should fit the text on one line")
    }

    // MARK: - Word boundary splitting

    func test_make_splitsAtWordBoundaryWhenTextExceedsBudget() {
        // Use a narrow input so text must wrap, with observedCharWidth for determinism
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 10, y: 80, width: 2, height: 18),
            inputFrameRect: CGRect(x: 0, y: 70, width: 140, height: 30),
            observedCharWidth: 7
        )

        let layout = GhostSuggestionLayout.make(
            text: " hello world testing",
            geometry: geometry,
            fontSize: 14,
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 300)
        )

        XCTAssertGreaterThan(layout.lines.count, 1)
        // Lines should break at word boundaries, not mid-word
        for line in layout.lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            XCTAssertFalse(trimmed.isEmpty, "No line should be empty after splitting")
        }
    }

    func test_make_splitsAtCharacterLevelWhenNoWhitespaceExists() {
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 10, y: 80, width: 2, height: 18),
            inputFrameRect: CGRect(x: 0, y: 70, width: 120, height: 30),
            observedCharWidth: 7
        )

        // A single long token with no spaces
        let layout = GhostSuggestionLayout.make(
            text: " abcdefghijklmnopqrstuvwxyz",
            geometry: geometry,
            fontSize: 14,
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 300)
        )

        XCTAssertGreaterThan(layout.lines.count, 1, "Long token should be split across lines")
    }

    // MARK: - startsBelowCaret

    func test_make_startsBelowCaretWhenFirstLineBudgetIsTooSmall() {
        // Place caret near the right edge of a narrow input
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 130, y: 80, width: 2, height: 18),
            inputFrameRect: CGRect(x: 0, y: 70, width: 140, height: 30),
            observedCharWidth: 7
        )

        let layout = GhostSuggestionLayout.make(
            text: " hello world overflow text here",
            geometry: geometry,
            fontSize: 14,
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 300)
        )

        XCTAssertLessThan(
            layout.topLineCenterOffsetFromCaret, 0,
            "Should start below caret when first line budget is too small"
        )
        XCTAssertEqual(layout.lines.first?.leadingIndent, 0)
    }

    // MARK: - panelFrame

    func test_panelFrame_positionsRelativeToCaret() {
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 50, y: 100, width: 2, height: 18),
            inputFrameRect: CGRect(x: 0, y: 90, width: 400, height: 30),
            observedCharWidth: 7
        )

        let layout = GhostSuggestionLayout.make(
            text: " short",
            geometry: geometry,
            fontSize: 14,
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 300)
        )

        let caretRect = CGRect(x: 50, y: 100, width: 2, height: 18)
        let contentSize = CGSize(width: 100, height: 20)
        let frame = layout.panelFrame(for: contentSize, caretRect: caretRect)

        // Panel X should match panelOriginX
        XCTAssertEqual(frame.origin.x, layout.panelOriginX)
        // Panel should be vertically centered around the caret midY
        let expectedTopCenter = caretRect.midY + layout.topLineCenterOffsetFromCaret
        let expectedY = expectedTopCenter - contentSize.height + (layout.lineHeight / 2)
        XCTAssertEqual(frame.origin.y, expectedY)
    }

    // MARK: - Fallback to visible frame

    func test_make_usesVisibleFrameFallbackWhenNoInputFrame() {
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 50, y: 100, width: 2, height: 18),
            inputFrameRect: nil,
            observedCharWidth: 7
        )

        let layout = GhostSuggestionLayout.make(
            text: " some text here",
            geometry: geometry,
            fontSize: 14,
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 300)
        )

        XCTAssertFalse(layout.lines.isEmpty, "Should still produce lines without an input frame")
    }

    // MARK: - RTL single-line layout

    func test_make_rtlSingleLineLayoutPlacesLeftOfCaret() {
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 200, y: 80, width: 2, height: 18),
            inputFrameRect: CGRect(x: 0, y: 70, width: 400, height: 30),
            observedCharWidth: 7,
            isRightToLeft: true
        )

        let layout = GhostSuggestionLayout.make(
            text: "مرحبا",
            geometry: geometry,
            fontSize: 14,
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 300)
        )

        XCTAssertEqual(layout.lines.count, 1)
        XCTAssertTrue(layout.isRightToLeft)
        XCTAssertEqual(layout.topLineCenterOffsetFromCaret, 0)
        // panelOriginX is a right-edge anchor for RTL, so it should be left of the caret
        XCTAssertLessThanOrEqual(layout.panelOriginX, geometry.caretRect.minX)
    }

    func test_panelFrame_rtlSubtractsContentWidth() {
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 200, y: 100, width: 2, height: 18),
            inputFrameRect: CGRect(x: 0, y: 90, width: 400, height: 30),
            observedCharWidth: 7,
            isRightToLeft: true
        )

        let layout = GhostSuggestionLayout.make(
            text: "مرحبا",
            geometry: geometry,
            fontSize: 14,
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 300)
        )

        let contentSize = CGSize(width: 80, height: 20)
        let frame = layout.panelFrame(for: contentSize, caretRect: geometry.caretRect)

        // RTL: actual origin.x = panelOriginX - contentSize.width
        XCTAssertEqual(frame.origin.x, layout.panelOriginX - contentSize.width)
        // Panel should be entirely to the left of the caret
        XCTAssertLessThan(frame.maxX, geometry.caretRect.minX)
    }

    // MARK: - RTL multi-line layout

    func test_make_rtlMultiLineWrapsCorrectly() {
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 200, y: 80, width: 2, height: 18),
            inputFrameRect: CGRect(x: 0, y: 70, width: 300, height: 30),
            observedCharWidth: 7,
            isRightToLeft: true
        )

        let layout = GhostSuggestionLayout.make(
            text: "هذا نص طويل جدا يحتاج إلى التفاف على عدة أسطر",
            geometry: geometry,
            fontSize: 14,
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 300)
        )

        XCTAssertGreaterThan(layout.lines.count, 1, "Should wrap to multiple lines in RTL")
        XCTAssertTrue(layout.isRightToLeft)
        XCTAssertEqual(layout.lines.last?.showsKeycap, true)
        for line in layout.lines.dropLast() {
            XCTAssertFalse(line.showsKeycap)
        }
    }

    func test_make_rtlStartsBelowCaretWhenLeftBudgetTooSmall() {
        // Caret near the left edge — no room to the left
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 15, y: 80, width: 2, height: 18),
            inputFrameRect: CGRect(x: 0, y: 70, width: 300, height: 30),
            observedCharWidth: 7,
            isRightToLeft: true
        )

        let layout = GhostSuggestionLayout.make(
            text: "نص عربي طويل يحتاج مساحة كبيرة",
            geometry: geometry,
            fontSize: 14,
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 300)
        )

        XCTAssertLessThan(
            layout.topLineCenterOffsetFromCaret, 0,
            "Should start below caret when left budget is too small for RTL"
        )
    }
}
