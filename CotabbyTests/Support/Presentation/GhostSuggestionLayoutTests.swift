import AppKit
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

    // MARK: - Line identity

    func test_make_lineIdsMatchLineIndices() {
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 10, y: 80, width: 2, height: 18),
            inputFrameRect: CGRect(x: 0, y: 70, width: 400, height: 30),
            observedCharWidth: 7
        )

        let layout = GhostSuggestionLayout.make(
            text: "hello\nworld",
            geometry: geometry,
            fontSize: 14,
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 300)
        )

        XCTAssertEqual(layout.lines.map(\.id), layout.lines.map(\.index))
        XCTAssertEqual(layout.lines.map(\.id), [0, 1])
    }

    // MARK: - Explicit newlines

    func test_make_explicitNewlineForcesLineBreakAtThatPoint() {
        // usable frame: minX = max(0 + 8, 0 + 16) = 16; caret anchor = 12 + 6 = 18, so the first
        // line is indented 2pt from the panel origin and the wrapped line starts at the origin.
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 10, y: 80, width: 2, height: 18),
            inputFrameRect: CGRect(x: 0, y: 70, width: 400, height: 30),
            observedCharWidth: 7
        )

        let layout = GhostSuggestionLayout.make(
            text: "hello\nworld",
            geometry: geometry,
            fontSize: 14,
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 300)
        )

        XCTAssertEqual(layout.lines.map(\.text), ["hello", "world"])
        XCTAssertEqual(layout.lines[0].leadingIndent, 2)
        XCTAssertEqual(layout.lines[1].leadingIndent, 0)
        XCTAssertEqual(layout.topLineCenterOffsetFromCaret, 0)
        XCTAssertEqual(layout.panelOriginX, 16)
    }

    func test_make_leadingNewlineYieldsOnlyTheTextAfterIt() {
        // The empty segment before a leading newline is skipped, so the visible line is the text
        // after the break, still anchored at the caret.
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 10, y: 80, width: 2, height: 18),
            inputFrameRect: CGRect(x: 0, y: 70, width: 400, height: 30),
            observedCharWidth: 7
        )

        let layout = GhostSuggestionLayout.make(
            text: "\nworld",
            geometry: geometry,
            fontSize: 14,
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 300)
        )

        XCTAssertEqual(layout.lines.map(\.text), ["world"])
        XCTAssertEqual(layout.lines[0].leadingIndent, 2)
        XCTAssertEqual(layout.topLineCenterOffsetFromCaret, 0)
    }

    func test_make_newlineOnlyTextProducesOnePlaceholderLineBelowCaret() {
        // A suggestion that is just a line break has no splittable content: the layout falls back
        // to a single raw line and renders it below the caret instead of beside it.
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 10, y: 80, width: 2, height: 18),
            inputFrameRect: CGRect(x: 0, y: 70, width: 400, height: 30),
            observedCharWidth: 7
        )

        let layout = GhostSuggestionLayout.make(
            text: "\n",
            geometry: geometry,
            fontSize: 14,
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 300)
        )

        XCTAssertEqual(layout.lines.map(\.text), ["\n"])
        XCTAssertEqual(layout.lines[0].leadingIndent, 0)
        XCTAssertEqual(layout.lineHeight, 18, "ceil(14 * 1.25)")
        XCTAssertEqual(layout.topLineCenterOffsetFromCaret, -layout.lineHeight)
        XCTAssertEqual(layout.panelOriginX, 16)
    }

    func test_make_overwideSegmentBeforeNewlineWidthWrapsAndCarriesRemainder() {
        // usable: minX 16, maxX 492; first-line budget = 492 - 18 - 36 (keycap) = 438; at 10pt per
        // char the 60-char segment splits after 43 chars, and the leftover 17 chars must carry
        // forward together with the post-newline text as separate lines.
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 10, y: 80, width: 2, height: 18),
            inputFrameRect: CGRect(x: 0, y: 70, width: 500, height: 30),
            observedCharWidth: 10
        )

        let layout = GhostSuggestionLayout.make(
            text: String(repeating: "a", count: 60) + "\nrest",
            geometry: geometry,
            fontSize: 14,
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 600)
        )

        XCTAssertEqual(
            layout.lines.map(\.text),
            [String(repeating: "a", count: 43), String(repeating: "a", count: 17), "rest"]
        )
        XCTAssertEqual(layout.lines[0].leadingIndent, 2)
        XCTAssertEqual(layout.topLineCenterOffsetFromCaret, 0)
        XCTAssertEqual(layout.lines.last?.showsKeycap, true)
    }

    func test_make_overwideSingleCharacterSegmentStillEmitsItBeforeTheNewlineText() {
        // A single glyph wider than the whole budget cannot be split further: it must ship as its
        // own line (never an empty line) and the post-newline text follows, one glyph per line.
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 10, y: 80, width: 2, height: 18),
            inputFrameRect: CGRect(x: 0, y: 70, width: 500, height: 30),
            observedCharWidth: 500
        )

        let layout = GhostSuggestionLayout.make(
            text: "W\nnext",
            geometry: geometry,
            fontSize: 14,
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 600)
        )

        XCTAssertEqual(layout.lines.map(\.text), ["W", "n", "e", "x", "t"])
        XCTAssertEqual(layout.lines[0].leadingIndent, 2)
    }

    func test_make_trailingNewlineAfterOverwideSegmentKeepsWidthWrappedRemainder() {
        // Same overwide segment, but nothing follows the newline: the width-wrapped leftover is
        // the entire remainder and the trailing break adds no extra line.
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 10, y: 80, width: 2, height: 18),
            inputFrameRect: CGRect(x: 0, y: 70, width: 500, height: 30),
            observedCharWidth: 10
        )

        let layout = GhostSuggestionLayout.make(
            text: String(repeating: "a", count: 60) + "\n",
            geometry: geometry,
            fontSize: 14,
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 600)
        )

        XCTAssertEqual(
            layout.lines.map(\.text),
            [String(repeating: "a", count: 43), String(repeating: "a", count: 17)]
        )
    }

    // MARK: - RTL fallback frame (no input frame)

    func test_make_rtlWithoutInputFrameUsesAreaLeftOfCaret() {
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 300, y: 80, width: 2, height: 18),
            inputFrameRect: nil,
            observedCharWidth: 7,
            isRightToLeft: true
        )

        let layout = GhostSuggestionLayout.make(
            text: "مرحبا",
            geometry: geometry,
            fontSize: 14,
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 300)
        )

        // The fallback text frame runs from the screen margin to the caret gap, so the RTL anchor
        // is exactly caret.minX - 6.
        XCTAssertEqual(layout.lines.count, 1)
        XCTAssertEqual(layout.panelOriginX, 294)
        XCTAssertEqual(layout.topLineCenterOffsetFromCaret, 0)
        XCTAssertTrue(layout.isRightToLeft)
    }

    // MARK: - Width measurement without an observed char width

    func test_make_measuresWithFontWhenNoObservedCharWidth() {
        // No AX-observed average width: the layout must measure the rendered string with a real
        // font. The same 19-char text fits one line at the system fallback size but must wrap once
        // the host's (much wider) monospace font is supplied, proving the host font drives wrap.
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 10, y: 80, width: 2, height: 18),
            inputFrameRect: CGRect(x: 0, y: 70, width: 400, height: 30)
        )
        let visibleFrame = CGRect(x: 0, y: 0, width: 500, height: 300)
        let text = " brief reply coming"

        let systemMeasured = GhostSuggestionLayout.make(
            text: text,
            geometry: geometry,
            fontSize: 14,
            visibleFrame: visibleFrame
        )
        let hostMeasured = GhostSuggestionLayout.make(
            text: text,
            geometry: geometry,
            fontSize: 14,
            visibleFrame: visibleFrame,
            font: NSFont.monospacedSystemFont(ofSize: 40, weight: .regular)
        )

        XCTAssertEqual(systemMeasured.lines.count, 1)
        XCTAssertGreaterThan(hostMeasured.lines.count, 1)
    }

    // MARK: - renderedWidth (exact-advance measurement)

    func test_renderedWidth_emptyAndWhitespaceOnlyAreZero() {
        let font = NSFont.systemFont(ofSize: 14)
        XCTAssertEqual(GhostSuggestionLayout.renderedWidth(of: "", font: font), 0)
        XCTAssertEqual(GhostSuggestionLayout.renderedWidth(of: "   ", font: font), 0)
    }

    func test_renderedWidth_longerTailIsWider() {
        let font = NSFont.systemFont(ofSize: 14)
        let short = GhostSuggestionLayout.renderedWidth(of: "brown fox", font: font)
        let long = GhostSuggestionLayout.renderedWidth(of: "quick brown fox", font: font)
        XCTAssertGreaterThan(long, short)
    }

    /// The advance shift (width(before) - width(after)) must be positive when a leading word is
    /// handed off; that is what slides the panel so the remaining tail stays on the same pixels.
    func test_renderedWidth_prefixHandoffShiftIsPositive() {
        let font = NSFont.systemFont(ofSize: 14)
        let before = GhostSuggestionLayout.renderedWidth(of: "quick brown fox", font: font)
        let after = GhostSuggestionLayout.renderedWidth(of: "brown fox", font: font)
        XCTAssertGreaterThan(before - after, 0)
    }

    /// Width must not depend on how many spaces the raw tail contained, because the overlay renders
    /// the whitespace-collapsed display string.
    func test_renderedWidth_collapsesInternalWhitespace() {
        let font = NSFont.systemFont(ofSize: 14)
        let single = GhostSuggestionLayout.renderedWidth(of: "alpha beta", font: font)
        let multiple = GhostSuggestionLayout.renderedWidth(of: "alpha     beta", font: font)
        XCTAssertEqual(single, multiple, accuracy: 0.001)
    }

    func test_renderedWidth_largerFontIsWider() {
        let small = GhostSuggestionLayout.renderedWidth(of: "sample", font: NSFont.systemFont(ofSize: 12))
        let large = GhostSuggestionLayout.renderedWidth(of: "sample", font: NSFont.systemFont(ofSize: 24))
        XCTAssertGreaterThan(large, small)
    }
}
