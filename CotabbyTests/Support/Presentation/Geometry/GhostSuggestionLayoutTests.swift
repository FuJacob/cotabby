import AppKit
import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for the pure ghost-text line layout: where the first line anchors, how text wraps, where
/// wrapped lines start, and how the panel frame is derived from the rendered content size.
///
/// Most cases pin `observedCharWidth` so widths are exact (`characters * charWidth`) and every
/// expected value below can be traced by hand. The recurring arithmetic for the default geometry
/// (field x 0...400, screen x 0...500) is: usable region = `max(0 + 8, 0 + 16)` ... `min(400 - 8,
/// 500 - 16)` = 16...392, and the keycap reserves 36pt on the last line when the hint is shown.
final class GhostSuggestionLayoutTests: XCTestCase {

    /// Builds a layout with deterministic defaults so each test only states what it varies.
    private func makeLayout(
        _ text: String,
        caret: CGRect = CGRect(x: 10, y: 80, width: 2, height: 18),
        inputFrame: CGRect? = CGRect(x: 0, y: 70, width: 400, height: 30),
        charWidth: CGFloat? = 7,
        isRightToLeft: Bool = false,
        edges: ObservedContentEdges? = nil,
        visibleFrame: CGRect = CGRect(x: 0, y: 0, width: 500, height: 300),
        showsHint: Bool = true,
        font: NSFont? = nil
    ) -> GhostSuggestionLayout {
        GhostSuggestionLayout.make(
            text: text,
            geometry: CotabbyTestFixtures.overlayGeometry(
                caretRect: caret,
                inputFrameRect: inputFrame,
                observedCharWidth: charWidth,
                isRightToLeft: isRightToLeft,
                observedContentEdges: edges
            ),
            fontSize: 14,
            visibleFrame: visibleFrame,
            showsAcceptanceHint: showsHint,
            font: font
        )
    }

    // MARK: - Single-line layout

    func test_make_singleLineAnchorsFlushAtTheClampedCaret() {
        // Caret maxX 12 sits left of the usable minX 16, so the anchor clamps to 16. The leading
        // space is preserved because it carries the word spacing (no artificial caret gap).
        let layout = makeLayout(" hi")

        XCTAssertEqual(layout.lines, [
            GhostSuggestionLayout.Line(index: 0, text: " hi", leadingIndent: 0, showsKeycap: true)
        ])
        XCTAssertEqual(layout.panelOriginX, 16)
        XCTAssertEqual(layout.lineHeight, 18, "ceil(14 * 1.25)")
        XCTAssertEqual(layout.topLineCenterOffsetFromCaret, 0)
        XCTAssertFalse(layout.isRightToLeft)
        XCTAssertFalse(layout.wrappedLinesFollowHostMargin)
    }

    func test_make_singleLineOnASecondaryDisplayLeftOfThePrimary() {
        // Negative global X (a display arranged left of the primary) must not be clamped to 0:
        // usable = max(-992, -1424) ... min(-608, -16), so the anchor is the caret's maxX, -898.
        let layout = makeLayout(
            " hi",
            caret: CGRect(x: -900, y: 80, width: 2, height: 18),
            inputFrame: CGRect(x: -1000, y: 70, width: 400, height: 30),
            visibleFrame: CGRect(x: -1440, y: 0, width: 1440, height: 900)
        )

        XCTAssertEqual(layout.lines.map(\.text), [" hi"])
        XCTAssertEqual(layout.panelOriginX, -898)
    }

    // MARK: - Wrapping and the acceptance keycap

    func test_make_wrapsAtWordBoundariesAndShowsTheKeycapOnlyOnTheLastLine() {
        // Field 0...200 -> usable 16...192. With the keycap: budget 192 - 16 - 36 = 140 = 20 chars.
        let text = " alpha beta gamma delta epsilon zeta eta theta iota"
        let withHint = makeLayout(text, inputFrame: CGRect(x: 0, y: 70, width: 200, height: 30))

        XCTAssertEqual(withHint.lines.map(\.text), ["alpha beta gamma", "delta epsilon zeta", "eta theta iota"])
        XCTAssertEqual(withHint.lines.map(\.showsKeycap), [false, false, true])
        XCTAssertEqual(withHint.lines.map(\.id), [0, 1, 2])
        XCTAssertEqual(withHint.lines.map(\.leadingIndent), [0, 0, 0])

        // Without the keycap the budget is 176 = 25 chars, and no line shows a keycap.
        let withoutHint = makeLayout(
            text,
            inputFrame: CGRect(x: 0, y: 70, width: 200, height: 30),
            showsHint: false
        )
        XCTAssertEqual(withoutHint.lines.map(\.text), ["alpha beta gamma delta", "epsilon zeta eta theta", "iota"])
        XCTAssertEqual(withoutHint.lines.map(\.showsKeycap), [false, false, false])
    }

    func test_make_reclaimsKeycapWidthForTextWhenAcceptanceHintDisabled() {
        // 44 chars * 10pt = 440 sits between the first-line budget with the keycap reserved
        // (492 - 22 - 36 = 434) and without it (492 - 22 = 470): the same text wraps while the hint
        // is shown and fits on one line once its reserved width is handed back.
        let text = "aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii"
        let caret = CGRect(x: 20, y: 80, width: 2, height: 18)
        let inputFrame = CGRect(x: 0, y: 70, width: 500, height: 30)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 600)

        let withHint = makeLayout(
            text, caret: caret, inputFrame: inputFrame, charWidth: 10, visibleFrame: visibleFrame
        )
        let withoutHint = makeLayout(
            text, caret: caret, inputFrame: inputFrame, charWidth: 10, visibleFrame: visibleFrame,
            showsHint: false
        )

        XCTAssertEqual(withHint.lines.map(\.text), ["aaaa bbbb cccc dddd eeee ffff gggg hhhh", "iiii"])
        XCTAssertEqual(withoutHint.lines.map(\.text), [text])
    }

    func test_make_breaksAfterTheWhitespaceThatOverflows() {
        // Budget 132 - 16 - 36 = 80 (11 chars). The 12th character is the space itself, which
        // records the break before the width check fires, so "hello world" keeps its full word.
        let layout = makeLayout(" hello world testing", inputFrame: CGRect(x: 0, y: 70, width: 140, height: 30))

        XCTAssertEqual(layout.lines.map(\.text), ["hello world", "testing"])
    }

    func test_make_splitsAtCharacterLevelWhenNoWhitespaceExists() {
        // Budget 112 - 16 - 36 = 60 (8 chars at 7pt); a single token hard-splits every 8 chars.
        let layout = makeLayout(" abcdefghijklmnopqrstuvwxyz", inputFrame: CGRect(x: 0, y: 70, width: 120, height: 30))

        XCTAssertEqual(layout.lines.map(\.text), ["abcdefgh", "ijklmnop", "qrstuvwx", "yz"])
    }

    func test_make_startsBelowCaretWhenFirstLineBudgetIsTooSmall() {
        // Caret at the usable right edge (132): first-line budget 0 < 48, so every line wraps below
        // the caret at the region's left edge with the 80pt overflow budget.
        let layout = makeLayout(
            " hello world overflow text here",
            caret: CGRect(x: 130, y: 80, width: 2, height: 18),
            inputFrame: CGRect(x: 0, y: 70, width: 140, height: 30)
        )

        XCTAssertEqual(layout.lines.map(\.text), ["hello world", "overflow", "text here"])
        XCTAssertEqual(layout.topLineCenterOffsetFromCaret, -18)
        XCTAssertEqual(layout.panelOriginX, 16)
        XCTAssertEqual(layout.lines.map(\.leadingIndent), [0, 0, 0])
    }

    func test_make_fieldExtendingPastTheScreenEdgeIsClampedToTheVisibleFrame() {
        // Field 300...700 on a 500pt screen: usable = 308 ... min(692, 484) = 484. From caret 402
        // the first-line budget is 484 - 402 - 36 = 46 < 48, so the text moves below the caret
        // rather than running off-screen.
        let layout = makeLayout(
            " abcdefghi",
            caret: CGRect(x: 400, y: 80, width: 2, height: 18),
            inputFrame: CGRect(x: 300, y: 70, width: 400, height: 30)
        )

        XCTAssertEqual(layout.lines.map(\.text), ["abcdefghi"])
        XCTAssertEqual(layout.topLineCenterOffsetFromCaret, -18)
        XCTAssertEqual(layout.panelOriginX, 308)
    }

    // MARK: - Fallback region without a usable input frame

    func test_make_fallsBackToTheAreaRightOfTheCaretWithoutAUsableInputFrame() {
        // No frame, a frame narrower than the 48pt minimum, and a frame whose padded interior is
        // under 48pt (16...52) all use the fallback region, which starts caretGap (6) past the caret.
        let unusableFrames: [CGRect?] = [
            nil,
            CGRect(x: 0, y: 90, width: 40, height: 30),
            CGRect(x: 0, y: 90, width: 60, height: 30)
        ]

        for frame in unusableFrames {
            let layout = makeLayout(
                " some text here",
                caret: CGRect(x: 50, y: 100, width: 2, height: 18),
                inputFrame: frame
            )
            XCTAssertEqual(layout.lines.map(\.text), [" some text here"], "frame: \(String(describing: frame))")
            XCTAssertEqual(layout.panelOriginX, 58, "frame: \(String(describing: frame))")
        }
    }

    func test_make_rtlWithoutInputFrameUsesAreaLeftOfCaret() {
        // The RTL fallback region runs from the screen margin to caret.minX - 6 = 294.
        let layout = makeLayout(
            "مرحبا",
            caret: CGRect(x: 300, y: 80, width: 2, height: 18),
            inputFrame: nil,
            isRightToLeft: true
        )

        XCTAssertEqual(layout.lines.count, 1)
        XCTAssertEqual(layout.panelOriginX, 294)
        XCTAssertEqual(layout.topLineCenterOffsetFromCaret, 0)
        XCTAssertTrue(layout.isRightToLeft)
    }

    // MARK: - Right-to-left

    func test_make_rtlSingleLineEndsFlushAgainstTheCaret() {
        let caret = CGRect(x: 200, y: 100, width: 2, height: 18)
        let layout = makeLayout("مرحبا", caret: caret, inputFrame: CGRect(x: 0, y: 90, width: 400, height: 30), isRightToLeft: true)

        XCTAssertEqual(layout.lines.count, 1)
        XCTAssertEqual(layout.topLineCenterOffsetFromCaret, 0)
        // For RTL `panelOriginX` is the right-edge anchor: the caret's leading (left) edge.
        XCTAssertEqual(layout.panelOriginX, 200)

        let contentSize = CGSize(width: 80, height: 20)
        let frame = layout.panelFrame(for: contentSize, caretRect: caret)
        XCTAssertEqual(frame.origin.x, 120, "panelOriginX - content width")
        XCTAssertEqual(frame.maxX, caret.minX)
    }

    func test_make_rtlMultiLineAnchorsAtTheRegionRightEdgeAndIndentsTheCaretLine() {
        // Usable 16...292. The caret line (budget 200 - 16 - 36 = 148) is indented from the panel's
        // right anchor (292) back to the caret (200); wrapped lines hang from the right edge.
        let layout = makeLayout(
            "هذا نص طويل جدا يحتاج إلى التفاف على عدة أسطر",
            caret: CGRect(x: 200, y: 80, width: 2, height: 18),
            inputFrame: CGRect(x: 0, y: 70, width: 300, height: 30),
            isRightToLeft: true
        )

        XCTAssertEqual(layout.lines.count, 2)
        XCTAssertEqual(layout.panelOriginX, 292)
        XCTAssertEqual(layout.lines.map(\.leadingIndent), [92, 0])
        XCTAssertEqual(layout.lines.map(\.showsKeycap), [false, true])
        XCTAssertEqual(layout.topLineCenterOffsetFromCaret, 0)
    }

    func test_make_rtlStartsBelowCaretWhenLeftBudgetTooSmall() {
        // Caret at the usable left edge: no room leftward, so the whole text drops below the caret.
        let layout = makeLayout(
            "نص عربي طويل يحتاج مساحة كبيرة",
            caret: CGRect(x: 15, y: 80, width: 2, height: 18),
            inputFrame: CGRect(x: 0, y: 70, width: 300, height: 30),
            isRightToLeft: true
        )

        XCTAssertEqual(layout.lines.count, 1)
        XCTAssertEqual(layout.topLineCenterOffsetFromCaret, -18)
        XCTAssertEqual(layout.panelOriginX, 292)
        XCTAssertEqual(layout.lines.first?.leadingIndent, 0)
    }

    // MARK: - panelFrame

    func test_panelFrame_centersTheTopLineOnTheCaretUsingTheRenderedLineHeight() {
        // The top line is centered on caret.midY using the height the text actually rendered at
        // (`contentSize.height / lines.count`), not the `fontSize * 1.25` estimate in `lineHeight`:
        // the two disagree in practice, and positioning by the estimate shifted the ghost vertically.
        let caret = CGRect(x: 50, y: 100, width: 2, height: 18)
        let layout = makeLayout(" short", caret: caret, inputFrame: CGRect(x: 0, y: 90, width: 400, height: 30))

        // midY 109 - height 20 + rendered line 20 / 2 = 99.
        XCTAssertEqual(
            layout.panelFrame(for: CGSize(width: 100, height: 20), caretRect: caret),
            CGRect(x: 52, y: 99, width: 100, height: 20)
        )
    }

    func test_panelFrame_multiLineBelowCaretOffsetsByOneLineAndDividesByLineCount() {
        let caret = CGRect(x: 130, y: 80, width: 2, height: 18)
        let layout = makeLayout(
            " hello world overflow text here",
            caret: caret,
            inputFrame: CGRect(x: 0, y: 70, width: 140, height: 30)
        )
        XCTAssertEqual(layout.lines.count, 3)

        // Rendered line = 60 / 3 = 20; top center = midY 89 - 18 = 71; y = 71 - 60 + 10 = 21.
        XCTAssertEqual(
            layout.panelFrame(for: CGSize(width: 200, height: 60), caretRect: caret),
            CGRect(x: 16, y: 21, width: 200, height: 60)
        )
    }

    func test_panelFrame_withNoLinesFallsBackToTheEstimatedLineHeight() {
        // `make` always emits a line, but the frame math must not divide by zero for an empty value.
        let caret = CGRect(x: 0, y: 40, width: 2, height: 20)
        let ltr = GhostSuggestionLayout(
            lines: [], panelOriginX: 40, lineHeight: 18, topLineCenterOffsetFromCaret: 0, isRightToLeft: false
        )
        let rtl = GhostSuggestionLayout(
            lines: [], panelOriginX: 300, lineHeight: 18, topLineCenterOffsetFromCaret: 0, isRightToLeft: true
        )
        let size = CGSize(width: 120, height: 30)

        // midY 50 - 30 + 18 / 2 = 29.
        XCTAssertEqual(ltr.panelFrame(for: size, caretRect: caret), CGRect(x: 40, y: 29, width: 120, height: 30))
        XCTAssertEqual(rtl.panelFrame(for: size, caretRect: caret), CGRect(x: 180, y: 29, width: 120, height: 30))
    }

    // MARK: - Explicit newlines

    func test_make_explicitNewlineForcesLineBreakAtThatPoint() {
        let layout = makeLayout("hello\nworld")

        XCTAssertEqual(layout.lines.map(\.text), ["hello", "world"])
        XCTAssertEqual(layout.lines.map(\.id), [0, 1])
        XCTAssertEqual(layout.lines.map(\.leadingIndent), [0, 0])
        XCTAssertEqual(layout.lines.map(\.showsKeycap), [false, true])
        XCTAssertEqual(layout.topLineCenterOffsetFromCaret, 0)
        XCTAssertEqual(layout.panelOriginX, 16)
    }

    func test_make_leadingNewlineYieldsOnlyTheTextAfterIt() {
        // The empty segment before a leading newline is skipped, so the visible line is the text
        // after the break, still anchored at the caret.
        let layout = makeLayout("\nworld")

        XCTAssertEqual(layout.lines.map(\.text), ["world"])
        XCTAssertEqual(layout.lines[0].leadingIndent, 0)
        XCTAssertEqual(layout.topLineCenterOffsetFromCaret, 0)
    }

    func test_make_newlineOnlyTextProducesOnePlaceholderLineBelowCaret() {
        // A suggestion that is just a line break has no splittable content: the layout falls back
        // to a single raw line and renders it below the caret instead of beside it.
        let layout = makeLayout("\n")

        XCTAssertEqual(layout.lines.map(\.text), ["\n"])
        XCTAssertEqual(layout.lines[0].leadingIndent, 0)
        XCTAssertEqual(layout.topLineCenterOffsetFromCaret, -18)
        XCTAssertEqual(layout.panelOriginX, 16)
    }

    func test_make_overwideSegmentBeforeNewlineWidthWrapsAndCarriesRemainder() {
        // Usable 16...492; first-line budget = 492 - 16 - 36 = 440 = 44 chars at 10pt. The leftover
        // 16 chars carry forward ahead of the post-newline text, each on its own line.
        let layout = makeLayout(
            String(repeating: "a", count: 60) + "\nrest",
            inputFrame: CGRect(x: 0, y: 70, width: 500, height: 30),
            charWidth: 10,
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 600)
        )

        XCTAssertEqual(
            layout.lines.map(\.text),
            [String(repeating: "a", count: 44), String(repeating: "a", count: 16), "rest"]
        )
        XCTAssertEqual(layout.lines[0].leadingIndent, 0)
        XCTAssertEqual(layout.topLineCenterOffsetFromCaret, 0)
        XCTAssertEqual(layout.lines.map(\.showsKeycap), [false, false, true])
    }

    func test_make_trailingNewlineAfterOverwideSegmentKeepsWidthWrappedRemainder() {
        // Same overwide segment, but nothing follows the newline: the width-wrapped leftover is
        // the entire remainder and the trailing break adds no extra line.
        let layout = makeLayout(
            String(repeating: "a", count: 60) + "\n",
            inputFrame: CGRect(x: 0, y: 70, width: 500, height: 30),
            charWidth: 10,
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 600)
        )

        XCTAssertEqual(
            layout.lines.map(\.text),
            [String(repeating: "a", count: 44), String(repeating: "a", count: 16)]
        )
    }

    func test_make_overwideSingleCharacterSegmentStillEmitsItBeforeTheNewlineText() {
        // A single glyph wider than the whole budget cannot be split further: it must ship as its
        // own line (never an empty line) and the post-newline text follows, one glyph per line.
        let layout = makeLayout(
            "W\nnext",
            inputFrame: CGRect(x: 0, y: 70, width: 500, height: 30),
            charWidth: 500,
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 600)
        )

        XCTAssertEqual(layout.lines.map(\.text), ["W", "n", "e", "x", "t"])
        XCTAssertEqual(layout.lines[0].leadingIndent, 0)
    }

    // MARK: - Width measurement without an observed char width

    func test_make_measuresWithFontWhenNoObservedCharWidth() {
        // No AX-observed average width: the layout must measure the rendered string with a real
        // font. The same 19-char text fits one line at the system fallback size but must wrap once
        // the host's (much wider) monospace font is supplied, proving the host font drives wrap.
        let text = " brief reply coming"
        let systemMeasured = makeLayout(text, charWidth: nil)
        let hostMeasured = makeLayout(
            text,
            charWidth: nil,
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

    /// A leading space survives normalization (it is the word spacing the ghost renders), so it
    /// must count toward the advance; a run of leading spaces still collapses to one.
    func test_renderedWidth_keepsExactlyOneLeadingSpace() {
        let font = NSFont.systemFont(ofSize: 14)
        let bare = GhostSuggestionLayout.renderedWidth(of: "alpha", font: font)
        let oneSpace = GhostSuggestionLayout.renderedWidth(of: " alpha", font: font)
        let manySpaces = GhostSuggestionLayout.renderedWidth(of: "    alpha", font: font)

        XCTAssertGreaterThan(oneSpace, bare)
        XCTAssertEqual(manySpaces, oneSpace, accuracy: 0.001)
    }

    func test_renderedWidth_largerFontIsWider() {
        let small = GhostSuggestionLayout.renderedWidth(of: "sample", font: NSFont.systemFont(ofSize: 12))
        let large = GhostSuggestionLayout.renderedWidth(of: "sample", font: NSFont.systemFont(ofSize: 24))
        XCTAssertGreaterThan(large, small)
    }

    // MARK: - Wrapped lines follow the host's text margin

    /// Word-shaped geometry: the frame is the whole 800pt page, the caret sits near its right edge.
    private static let pageFrame = CGRect(x: 0, y: 0, width: 800, height: 900)
    private static let pageCaret = CGRect(x: 700, y: 800, width: 2, height: 18)
    private static let pageScreen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    private static let pageWrappingText = " wrapping text that is far too long to fit on the caret's own line"

    /// Word publishes the whole page as one `AXTextArea`, so its `AXFrame` left edge is the paper's
    /// edge rather than the document's text margin. Overflow lines anchored to the frame started
    /// roughly an inch left of where the host's own text wraps to. The diagnostics flag must then
    /// report that the margin was actually used.
    func test_make_overflowLinesAlignToMeasuredContentEdgeWhenAvailable() {
        let layout = makeLayout(
            Self.pageWrappingText,
            caret: Self.pageCaret,
            inputFrame: Self.pageFrame,
            charWidth: nil,
            edges: ObservedContentEdges(leftX: 140, topY: 860),
            visibleFrame: Self.pageScreen
        )

        XCTAssertGreaterThan(layout.lines.count, 1, "expected the text to wrap")
        XCTAssertEqual(layout.panelOriginX, 140, accuracy: 0.001)
        XCTAssertTrue(layout.wrappedLinesFollowHostMargin)
    }

    func test_make_overflowLinesFallBackToFramePaddingWithoutContentEdge() {
        // Every host that exposes no measured content edge wraps to the padded frame edge (16).
        let layout = makeLayout(
            Self.pageWrappingText,
            caret: Self.pageCaret,
            inputFrame: Self.pageFrame,
            charWidth: nil,
            visibleFrame: Self.pageScreen
        )

        XCTAssertGreaterThan(layout.lines.count, 1)
        XCTAssertEqual(layout.panelOriginX, 16, accuracy: 0.001)
        XCTAssertFalse(layout.wrappedLinesFollowHostMargin)
    }

    func test_make_contentEdgeOutsideTheFieldIsClampedBackIntoIt() {
        // A stale or mis-reported edge must never push ghost text off the field entirely: -5000 is
        // clamped to the frame's own left edge (100).
        let layout = makeLayout(
            Self.pageWrappingText,
            caret: Self.pageCaret,
            inputFrame: CGRect(x: 100, y: 0, width: 800, height: 900),
            charWidth: nil,
            edges: ObservedContentEdges(leftX: -5000, topY: 860),
            visibleFrame: Self.pageScreen
        )

        XCTAssertEqual(layout.panelOriginX, 100, accuracy: 0.001)
        XCTAssertTrue(layout.wrappedLinesFollowHostMargin)
    }

    func test_make_singleLineAtCaretDoesNotClaimTheMeasuredMargin() {
        // The margin exists, but a short suggestion anchors at the caret, which lies past it.
        let layout = makeLayout(
            " hi",
            caret: CGRect(x: 200, y: 800, width: 2, height: 18),
            inputFrame: Self.pageFrame,
            charWidth: nil,
            edges: ObservedContentEdges(leftX: 140, topY: 860),
            visibleFrame: Self.pageScreen
        )

        XCTAssertEqual(layout.lines.count, 1)
        XCTAssertFalse(layout.wrappedLinesFollowHostMargin)
    }

    func test_make_screenMarginOverridingTheMeasuredEdgeIsNotReportedAsHostMargin() {
        // A 10pt margin sits inside the 16pt screen inset, so wrapped lines start at 16, not 10;
        // the flag must describe the edge actually used. The mirrored right edge (800 - 10 = 790)
        // is still right of the caret, so it bounds every line.
        let layout = makeLayout(
            longSuggestion,
            caret: Self.pageCaret,
            inputFrame: Self.pageFrame,
            charWidth: 10,
            edges: .lineQueryMargin(leftX: 10),
            visibleFrame: Self.pageScreen,
            showsHint: false
        )

        XCTAssertGreaterThan(layout.lines.count, 2)
        XCTAssertEqual(layout.panelOriginX, 16, accuracy: 0.001)
        XCTAssertFalse(layout.wrappedLinesFollowHostMargin)
        XCTAssertLessThanOrEqual(rightmostLineEdge(of: layout), 790 + 0.001)
    }

    func test_make_marginTooCloseToTheRightEdgeIsDropped() {
        // Field 0...200 with a margin at 180 leaves 192 - 180 = 12pt for wrapped lines, under the
        // 48pt minimum, so the margin is ignored and the padded frame (16...192) is used instead.
        let layout = makeLayout(
            longSuggestion,
            caret: CGRect(x: 100, y: 800, width: 2, height: 18),
            inputFrame: CGRect(x: 0, y: 0, width: 200, height: 900),
            charWidth: 10,
            edges: .lineQueryMargin(leftX: 180),
            visibleFrame: Self.pageScreen,
            showsHint: false
        )

        XCTAssertEqual(layout.lines.first?.text, "alpha", "first-line budget 192 - 102 = 90 (9 chars)")
        XCTAssertEqual(layout.panelOriginX, 16, accuracy: 0.001)
        XCTAssertEqual(layout.lines[0].leadingIndent, 86, accuracy: 0.001, "caret maxX 102 - 16")
        for line in layout.lines.dropFirst() {
            XCTAssertEqual(line.leadingIndent, 0, accuracy: 0.001)
        }
        XCTAssertFalse(layout.wrappedLinesFollowHostMargin)
    }

    // MARK: - A measured margin never moves the caret's own line

    /// Long enough to wrap several times at 10pt per character in every geometry below.
    private let longSuggestion = String(
        repeating: " alpha beta gamma delta epsilon zeta eta theta iota kappa lambda",
        count: 3
    )

    /// Reproduced in Word: a first-line indent measured on line 1 (x 360) while the caret sits near
    /// the start of line 2 (x 324). The margin used to clamp the first-line anchor, so the ghost
    /// started 36pt right of the caret. It must stay flush against the caret.
    func test_make_marginRightOfTheCaretNeverDetachesASingleLine() {
        let caret = CGRect(x: 324, y: 500, width: 2, height: 18)
        let layout = makeLayout(
            " hi",
            caret: caret,
            inputFrame: CGRect(x: 0, y: 0, width: 1000, height: 900),
            charWidth: nil,
            edges: .lineQueryMargin(leftX: 360),
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 1000)
        )

        XCTAssertEqual(layout.lines.count, 1)
        XCTAssertEqual(layout.panelOriginX, caret.maxX, accuracy: 0.001)
    }

    /// The same geometry with a wrapping suggestion: the caret's line stays on the caret and only
    /// the wrapped lines are indented out to the margin.
    func test_make_marginRightOfTheCaretIndentsOnlyTheWrappedLines() {
        let layout = makeLayout(
            longSuggestion,
            caret: CGRect(x: 324, y: 500, width: 2, height: 18),
            inputFrame: CGRect(x: 0, y: 0, width: 1000, height: 900),
            charWidth: 10,
            edges: .lineQueryMargin(leftX: 360),
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 1000),
            showsHint: false
        )

        XCTAssertGreaterThan(layout.lines.count, 2)
        XCTAssertEqual(layout.topLineCenterOffsetFromCaret, 0, "the first line continues the caret's line")
        XCTAssertEqual(layout.panelOriginX, 326, accuracy: 0.001)
        XCTAssertEqual(layout.lines[0].leadingIndent, 0, accuracy: 0.001)
        for line in layout.lines.dropFirst() {
            XCTAssertEqual(line.leadingIndent, 34, accuracy: 0.001, "wrapped lines start at the margin (360)")
        }
        XCTAssertTrue(layout.wrappedLinesFollowHostMargin)
    }

    /// The left edge of a right-to-left line is its ragged end, not a margin, so an RTL layout must
    /// come out exactly as if nothing had been measured.
    func test_make_rightToLeftIgnoresTheMeasuredMargin() {
        func layout(edges: ObservedContentEdges?) -> GhostSuggestionLayout {
            makeLayout(
                longSuggestion,
                caret: CGRect(x: 700, y: 500, width: 2, height: 18),
                inputFrame: CGRect(x: 0, y: 0, width: 1000, height: 900),
                charWidth: 10,
                isRightToLeft: true,
                edges: edges,
                visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 1000)
            )
        }

        XCTAssertEqual(layout(edges: .lineQueryMargin(leftX: 360)), layout(edges: nil))
    }

    // MARK: - The measured margin mirrors onto the right edge

    /// Word's frame is the whole page. With a 140pt left margin measured on an 800pt page, the text
    /// column's right edge is 660, not the page edge's 792, so no ghost line may run past 660.
    func test_make_lineQueryMarginMirrorsOntoTheRightEdge() {
        let layout = makeLayout(
            longSuggestion,
            caret: CGRect(x: 300, y: 800, width: 2, height: 18),
            inputFrame: Self.pageFrame,
            charWidth: 10,
            edges: .lineQueryMargin(leftX: 140),
            visibleFrame: Self.pageScreen,
            showsHint: false
        )

        XCTAssertGreaterThan(layout.lines.count, 2)
        XCTAssertLessThanOrEqual(rightmostLineEdge(of: layout), 660 + 0.001)
    }

    /// A caret right of the mirrored edge disproves the symmetric-margin assumption (the host never
    /// draws past its own right margin), so the frame's edge stands. Applying the mirror here would
    /// have pulled the ghost back over text the user already typed.
    func test_make_mirroredRightEdgeIsIgnoredWhenTheCaretIsPastIt() {
        let layout = makeLayout(
            " hi",
            caret: Self.pageCaret,
            inputFrame: Self.pageFrame,
            charWidth: nil,
            edges: .lineQueryMargin(leftX: 140),
            visibleFrame: Self.pageScreen
        )

        XCTAssertEqual(layout.lines.count, 1)
        XCTAssertEqual(layout.panelOriginX, Self.pageCaret.maxX, accuracy: 0.001)
    }

    /// Run-measured edges come from web editors whose frame already hugs the text; mirroring their
    /// left padding would only narrow the wrap, so their right edge stays the frame's.
    func test_make_runMeasuredEdgesKeepTheFrameRightEdge() {
        let layout = makeLayout(
            longSuggestion,
            caret: CGRect(x: 300, y: 800, width: 2, height: 18),
            inputFrame: Self.pageFrame,
            charWidth: 10,
            edges: ObservedContentEdges(leftX: 140, topY: 860, isRunMeasured: true),
            visibleFrame: Self.pageScreen,
            showsHint: false
        )

        XCTAssertGreaterThan(rightmostLineEdge(of: layout), 660)
    }

    /// The rightmost x any line reaches, at the fixtures' exact 10pt per character.
    private func rightmostLineEdge(of layout: GhostSuggestionLayout) -> CGFloat {
        layout.lines
            .map { layout.panelOriginX + $0.leadingIndent + CGFloat(($0.text as NSString).length) * 10 }
            .max() ?? 0
    }
}
