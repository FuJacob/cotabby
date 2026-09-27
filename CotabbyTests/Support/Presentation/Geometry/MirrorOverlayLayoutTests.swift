import CoreGraphics
import XCTest
@testable import Cotabby

/// Locks in the positioning, sizing, clamping, and fallback rules for the mirror-overlay card. The
/// layout is pure value math (no AppKit windows), so these tests run fast and isolate regressions to
/// a single helper.
///
/// Recurring numbers: at the default 13pt font the card is `ceil(13 * 1.6) + 2 * 4` = 29pt tall,
/// the anchor gap is 1pt, and the screen margin is 12pt. The final frame is `.integral`, so origins
/// computed from integer carets stay exact.
final class MirrorOverlayLayoutTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private static let allReasons: [CompletionRenderMode.MirrorReason] = [
        .caretGeometryEstimated, .caretLayoutEstimated, .userPreference, .perAppOverride, .caretMidLine
    ]

    private func makeLayout(
        _ suggestion: String = "hello",
        caret: CGRect = CGRect(x: 720, y: 500, width: 2, height: 18),
        inputFrame: CGRect? = CGRect(x: 400, y: 400, width: 640, height: 200),
        isRightToLeft: Bool = false,
        visibleFrame: CGRect? = nil,
        showsHint: Bool = true,
        autoAcceptTrailingPunctuation: Bool = true,
        sizeMultiplier: CGFloat = 1,
        reason: CompletionRenderMode.MirrorReason = .userPreference
    ) -> MirrorOverlayLayout {
        MirrorOverlayLayout.make(
            suggestion: suggestion,
            geometry: CotabbyTestFixtures.overlayGeometry(
                caretRect: caret,
                inputFrameRect: inputFrame,
                isRightToLeft: isRightToLeft
            ),
            visibleFrame: visibleFrame ?? screen,
            showsAcceptanceHint: showsHint,
            autoAcceptTrailingPunctuation: autoAcceptTrailingPunctuation,
            sizeMultiplier: sizeMultiplier,
            reason: reason
        )
    }

    // MARK: - Vertical anchor

    /// Every reason anchors just under the caret line. For trusted reasons the caret is precise; for
    /// `.caretGeometryEstimated` the resolver centers single-line estimates inside the field chrome
    /// and bottom-aligns multiline ones (caret.minY == field.minY), so following the caret line
    /// preserves the conservative field-bottom placement where that is all AX offers. The field's
    /// bottom (y 400) is ~100pt below the caret, and dropping to it was the original bug.
    func test_make_everyReasonSitsTightlyBelowANonEmptyCaret() {
        for reason in Self.allReasons {
            for inputFrame in [CGRect(x: 400, y: 400, width: 640, height: 200), nil] {
                let layout = makeLayout(inputFrame: inputFrame, reason: reason)
                let label = "reason: \(reason), frame: \(String(describing: inputFrame))"

                XCTAssertEqual(layout.panelFrame.maxY, 499, accuracy: 0.001, label)
                XCTAssertEqual(layout.panelFrame.height, 29, label)
                XCTAssertEqual(layout.reason, reason, label)
            }
        }
    }

    func test_make_emptyCaretAnchorsBelowAndCentersOnTheInputFrameForEveryReason() {
        // A zero caret rect is the degenerate shape some hosts publish right after focus: the
        // safety-net anchor is just below the field's bottom edge, centered on the field, in either
        // writing direction.
        let inputFrame = CGRect(x: 100, y: 100, width: 200, height: 40)
        for reason in Self.allReasons {
            for isRightToLeft in [false, true] {
                let layout = makeLayout(
                    "hi", caret: .zero, inputFrame: inputFrame, isRightToLeft: isRightToLeft, reason: reason
                )
                let label = "reason: \(reason), rtl: \(isRightToLeft)"

                XCTAssertEqual(layout.panelFrame.minY, 70, label)
                XCTAssertEqual(layout.panelFrame.midX, inputFrame.midX, label)
            }
        }
    }

    func test_make_zeroWidthCaretAwayFromTheOriginAnchorsXToTheCaretButYToTheField() {
        // `CGRect.isEmpty` is true for a zero-width rect, so the vertical anchor falls back to the
        // field bottom (400 - 1), while the horizontal anchor only needs a non-zero caret X.
        let layout = makeLayout(caret: CGRect(x: 300, y: 500, width: 0, height: 18), showsHint: false)

        XCTAssertEqual(layout.panelFrame.minX, 300)
        XCTAssertEqual(layout.panelFrame.maxY, 399, accuracy: 0.001)
    }

    // MARK: - Horizontal anchor

    func test_make_alignsLeftCardEdgeToLTRCaret() {
        let layout = makeLayout(showsHint: false)

        XCTAssertEqual(layout.panelFrame.minX, 722, "LTR card begins at the caret's trailing edge")
        XCTAssertFalse(layout.isRightToLeft)
    }

    func test_make_alignsRightCardEdgeToRTLCaret() {
        let layout = makeLayout(isRightToLeft: true, showsHint: false)

        XCTAssertEqual(layout.panelFrame.maxX, 720, accuracy: 0.001, "RTL card ends at the caret's trailing edge")
        XCTAssertTrue(layout.isRightToLeft)
    }

    // MARK: - Screen-edge clamping

    func test_make_clampsCardToVisibleFrameEdges() {
        // Right: the card would start at 1437; it is pulled back so it ends at the 12pt margin.
        let right = makeLayout(
            "this is a fairly long completion that would overflow",
            caret: CGRect(x: 1435, y: 500, width: 2, height: 18),
            reason: .caretGeometryEstimated
        )
        XCTAssertEqual(right.panelFrame.maxX, 1428, accuracy: 1)

        // Left: a card starting at x 4 moves out to the margin.
        let left = makeLayout("left edge test", caret: CGRect(x: 2, y: 500, width: 2, height: 18))
        XCTAssertEqual(left.panelFrame.minX, 12)

        // Bottom: 11 - 29 = -18 is pushed up to the margin.
        let bottom = makeLayout("near bottom edge", caret: CGRect(x: 500, y: 12, width: 2, height: 18))
        XCTAssertEqual(bottom.panelFrame.minY, 12)

        // Top: 949 - 29 = 920 is pulled down to 900 - 12 - 29 = 859.
        let top = makeLayout("near top edge", caret: CGRect(x: 500, y: 950, width: 2, height: 18))
        XCTAssertEqual(top.panelFrame.minY, 859)
    }

    func test_make_clampsWithinAVisibleFrameWithNegativeOrigin() {
        // A display left of the primary has negative X; clamping must use its own bounds.
        let secondary = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let inside = makeLayout(caret: CGRect(x: -800, y: 500, width: 2, height: 18), visibleFrame: secondary)
        XCTAssertEqual(inside.panelFrame.minX, -798)

        let pastLeftEdge = makeLayout(caret: CGRect(x: -1439, y: 500, width: 2, height: 18), visibleFrame: secondary)
        XCTAssertEqual(pastLeftEdge.panelFrame.minX, -1428)
    }

    func test_make_emptyCaretRectAndMissingInputFrame_clampsToScreenMargin() {
        // With no usable anchor at all, the caret fallback (0, -1) lands off-screen and the clamp
        // must pull the card back to the visible frame's margin.
        let layout = makeLayout("hi", caret: .zero, inputFrame: nil)

        XCTAssertEqual(layout.panelFrame.origin, CGPoint(x: 12, y: 12))
        XCTAssertEqual(layout.panelFrame.height, 29)
    }

    func test_make_pinsCardToMarginWhenVisibleFrameIsSmallerThanCard() {
        // When the visible frame cannot contain the card at all (tiny screen or extreme zoom), the
        // min/max clamp inverts; the layout pins to the leading margin on both axes.
        let layout = makeLayout(
            "hi",
            caret: CGRect(x: 60, y: 200, width: 2, height: 18),
            inputFrame: nil,
            visibleFrame: CGRect(x: 0, y: 0, width: 80, height: 28)
        )

        XCTAssertEqual(layout.panelFrame.origin, CGPoint(x: 12, y: 12))
        XCTAssertEqual(layout.panelFrame.height, 29)
    }

    // MARK: - Card sizing

    func test_make_acceptanceHintAddsExactlyTheKeycapReservation() {
        // The card hugs the measured text; the hint adds the fixed 36pt keycap on top of it.
        let withHint = makeLayout("abc", showsHint: true)
        let withoutHint = makeLayout("abc", showsHint: false)

        XCTAssertEqual(withHint.panelFrame.width - withoutHint.panelFrame.width, 36)
        XCTAssertLessThan(withHint.panelFrame.width, 176, "no minimum text width is imposed")
    }

    func test_make_longSuggestionCapsTheCardAtTheMaximumWidth() {
        // Text is clamped so text + keycap never exceeds 520, plus 2 * 10 padding: 540 either way.
        let long = String(repeating: "completion ", count: 40)

        XCTAssertEqual(makeLayout(long, showsHint: true).panelFrame.width, 540)
        XCTAssertEqual(makeLayout(long, showsHint: false).panelFrame.width, 540)
    }

    func test_make_sizeMultiplierScalesTheFixedFontWithALegibilityFloor() {
        // 13 * 2 = 26pt -> height ceil(41.6) + 8 = 50.
        let doubled = makeLayout(sizeMultiplier: 2)
        XCTAssertEqual(doubled.fontSize, 26, accuracy: 0.0001)
        XCTAssertEqual(doubled.panelFrame.height, 50)

        // 13 * 0.5 = 6.5pt is below the shared 9pt floor -> height ceil(14.4) + 8 = 23.
        let halved = makeLayout(sizeMultiplier: 0.5)
        XCTAssertEqual(halved.fontSize, GhostFontMetrics.absoluteMinimumPointSize)
        XCTAssertEqual(halved.panelFrame.height, 23)

        XCTAssertEqual(makeLayout().fontSize, 13)
    }

    // MARK: - Text normalization and highlight

    func test_make_collapsesWhitespaceInSuggestion() {
        // Mirror mode is single-line by design: explicit newlines and runs of whitespace collapse
        // to single spaces, and the edges are trimmed.
        XCTAssertEqual(makeLayout("  hello\n\nworld   foo  ").suggestionText, "hello world foo")
    }

    func test_make_whitespaceOnlySuggestionHasNoTextAndNoHighlight() {
        let layout = makeLayout(" \n\t ")

        XCTAssertEqual(layout.suggestionText, "")
        XCTAssertEqual(layout.highlightedPrefix, "")
    }

    func test_make_highlightsFirstWordAsAcceptancePrefix() {
        // The highlighted run is the first accept-word and is always a prefix of the displayed text,
        // so the renderer can split it off by length safely.
        let layout = makeLayout("tomorrow afternoon at noon")

        XCTAssertEqual(layout.highlightedPrefix, "tomorrow")
        XCTAssertTrue(layout.suggestionText.hasPrefix(layout.highlightedPrefix))
    }

    func test_make_highlightFollowsTheTrailingPunctuationSetting() {
        // Matches the accept-word chunk: with the setting off, trailing punctuation is its own part,
        // so the highlight stops before it.
        XCTAssertEqual(makeLayout("you? me").highlightedPrefix, "you?")
        XCTAssertEqual(makeLayout("you? me", autoAcceptTrailingPunctuation: false).highlightedPrefix, "you")
    }
}
