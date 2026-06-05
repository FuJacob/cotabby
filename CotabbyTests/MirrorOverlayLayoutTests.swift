import CoreGraphics
import XCTest
@testable import Cotabby

/// Locks in the positioning, clamping, and fallback rules for the mirror-overlay card. The layout
/// is pure value math (no AppKit windows), so these tests run fast and isolate regressions to a
/// single helper.
final class MirrorOverlayLayoutTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    // MARK: - Anchoring to the input field

    func test_make_anchorsBelowInputFrameWhenAvailable() {
        // Field sits in the middle of the screen with its bottom edge at y=400. The card should
        // appear below it (lower y in AppKit's bottom-up coordinate system).
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 720, y: 405, width: 2, height: 18),
            inputFrameRect: CGRect(x: 400, y: 400, width: 640, height: 30)
        )

        let layout = MirrorOverlayLayout.make(
            suggestion: "tomorrow afternoon",
            geometry: geometry,
            visibleFrame: screen,
            showsAcceptanceHint: true,
            reason: .caretGeometryEstimated
        )

        XCTAssertLessThan(
            layout.panelFrame.maxY,
            geometry.inputFrameRect!.minY,
            "Card should sit below the input field"
        )
        XCTAssertEqual(layout.suggestionText, "tomorrow afternoon")
        XCTAssertEqual(layout.reason, .caretGeometryEstimated)
    }

    func test_make_centersCardOnCaretX() {
        let caretX: CGFloat = 720
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: caretX, y: 500, width: 2, height: 18),
            inputFrameRect: CGRect(x: 400, y: 480, width: 640, height: 30)
        )

        let layout = MirrorOverlayLayout.make(
            suggestion: "hello",
            geometry: geometry,
            visibleFrame: screen,
            showsAcceptanceHint: false,
            reason: .userPreference
        )

        // Card center should be within 1pt of caret center after .integral rounding.
        XCTAssertLessThanOrEqual(
            abs(layout.panelFrame.midX - (caretX + 1)),
            1.5,
            "Card center should align horizontally to caret X"
        )
    }

    // MARK: - Caret-anchored path (user-forced / per-app-forced popup)

    func test_make_userPreferenceAnchorsToCaretLine_notInputField() {
        // The field's bottom edge (minY in AppKit coordinates) is at y=400. The caret line sits at
        // y=500, far above the field's bottom edge. Pre-fix behavior anchored to the field minY
        // even with .userPreference reason, dropping the popup ~100pt below where the eye is. The
        // fix uses caret.minY for user/perApp reasons so the popup tracks the cursor.
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 720, y: 500, width: 2, height: 18),
            inputFrameRect: CGRect(x: 400, y: 400, width: 640, height: 200)
        )

        let userPreferenceLayout = MirrorOverlayLayout.make(
            suggestion: "hello",
            geometry: geometry,
            visibleFrame: screen,
            showsAcceptanceHint: true,
            reason: .userPreference
        )

        // Card must sit close to the caret line (within one card-height worth of slack), not at the
        // field's bottom edge.
        XCTAssertLessThan(
            userPreferenceLayout.panelFrame.maxY,
            geometry.caretRect.minY,
            "User-forced popup should sit below the caret line"
        )
        XCTAssertGreaterThan(
            userPreferenceLayout.panelFrame.maxY,
            geometry.inputFrameRect!.minY + 40,
            "User-forced popup should NOT drop down to the field's bottom edge"
        )
    }

    func test_make_perAppOverrideAnchorsToCaretLine() {
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 720, y: 500, width: 2, height: 18),
            inputFrameRect: CGRect(x: 400, y: 400, width: 640, height: 200)
        )

        let layout = MirrorOverlayLayout.make(
            suggestion: "hello",
            geometry: geometry,
            visibleFrame: screen,
            showsAcceptanceHint: true,
            reason: .perAppOverride
        )

        XCTAssertLessThan(
            layout.panelFrame.maxY,
            geometry.caretRect.minY,
            "Per-app forced popup should also sit below the caret line, not the field"
        )
    }

    func test_make_estimatedReasonStillAnchorsToInputField() {
        // Same geometry as the user-preference test above, but with .caretGeometryEstimated. The
        // caret rect is exactly the kind of value that can't be trusted in this case, so the layout
        // must keep the field-rect anchor it had before the fix.
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 720, y: 500, width: 2, height: 18),
            inputFrameRect: CGRect(x: 400, y: 400, width: 640, height: 200)
        )

        let layout = MirrorOverlayLayout.make(
            suggestion: "hello",
            geometry: geometry,
            visibleFrame: screen,
            showsAcceptanceHint: true,
            reason: .caretGeometryEstimated
        )

        // Card sits below the FIELD edge, well below the caret line.
        XCTAssertLessThan(
            layout.panelFrame.maxY,
            geometry.inputFrameRect!.minY,
            "Estimated-reason popup should still anchor below the input field rect"
        )
    }

    // MARK: - Fallback when input frame missing

    func test_make_fallsBackToCaretRectWhenInputFrameMissing() {
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 200, y: 600, width: 2, height: 18),
            inputFrameRect: nil
        )

        let layout = MirrorOverlayLayout.make(
            suggestion: "fallback",
            geometry: geometry,
            visibleFrame: screen,
            showsAcceptanceHint: true,
            reason: .caretGeometryEstimated
        )

        // The card should still land below the caret rect since no field rect is available. The
        // fallback uses a fixed vertical offset, so the card's maxY is strictly less than the caret
        // rect's minY (with some tolerance for the gap).
        XCTAssertLessThan(layout.panelFrame.maxY, geometry.caretRect.minY)
    }

    // MARK: - Screen-edge clamping

    func test_make_clampsCardToVisibleFrame_rightEdge() {
        // Caret near the right edge — card would overflow without clamping.
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: screen.maxX - 5, y: 500, width: 2, height: 18),
            inputFrameRect: CGRect(x: screen.maxX - 100, y: 480, width: 100, height: 30)
        )

        let layout = MirrorOverlayLayout.make(
            suggestion: "this is a fairly long completion that would overflow",
            geometry: geometry,
            visibleFrame: screen,
            showsAcceptanceHint: true,
            reason: .caretGeometryEstimated
        )

        XCTAssertLessThanOrEqual(layout.panelFrame.maxX, screen.maxX)
        XCTAssertGreaterThanOrEqual(layout.panelFrame.minX, screen.minX)
    }

    func test_make_clampsCardToVisibleFrame_leftEdge() {
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: screen.minX + 2, y: 500, width: 2, height: 18),
            inputFrameRect: CGRect(x: screen.minX, y: 480, width: 80, height: 30)
        )

        let layout = MirrorOverlayLayout.make(
            suggestion: "left edge test",
            geometry: geometry,
            visibleFrame: screen,
            showsAcceptanceHint: true,
            reason: .caretGeometryEstimated
        )

        XCTAssertGreaterThanOrEqual(layout.panelFrame.minX, screen.minX)
    }

    func test_make_clampsCardToVisibleFrame_bottomEdge() {
        // Field near the bottom of the screen; card would otherwise be clipped below the visible
        // region. With clamping it should be pushed up to fit on-screen.
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 500, y: screen.minY + 12, width: 2, height: 18),
            inputFrameRect: CGRect(x: 400, y: screen.minY + 5, width: 300, height: 30)
        )

        let layout = MirrorOverlayLayout.make(
            suggestion: "near bottom edge",
            geometry: geometry,
            visibleFrame: screen,
            showsAcceptanceHint: false,
            reason: .userPreference
        )

        XCTAssertGreaterThanOrEqual(layout.panelFrame.minY, screen.minY)
    }

    // MARK: - Text normalization

    func test_make_collapsesWhitespaceInSuggestion() {
        let geometry = CotabbyTestFixtures.overlayGeometry()
        let layout = MirrorOverlayLayout.make(
            suggestion: "  hello\n\nworld   foo  ",
            geometry: geometry,
            visibleFrame: screen,
            showsAcceptanceHint: false,
            reason: .userPreference
        )

        // Mirror mode is single-line by design: explicit newlines and runs of whitespace collapse
        // to single spaces.
        XCTAssertEqual(layout.suggestionText, "hello world foo")
    }

    // MARK: - First-word highlight

    func test_make_highlightsFirstWordAsAcceptancePrefix() {
        let geometry = CotabbyTestFixtures.overlayGeometry()
        let layout = MirrorOverlayLayout.make(
            suggestion: "tomorrow afternoon at noon",
            geometry: geometry,
            visibleFrame: screen,
            showsAcceptanceHint: true,
            reason: .userPreference
        )

        // The highlighted run is the first accept-word and is always a prefix of the displayed text,
        // so the renderer can split it off by length safely.
        XCTAssertEqual(layout.highlightedPrefix, "tomorrow")
        XCTAssertTrue(layout.suggestionText.hasPrefix(layout.highlightedPrefix))
    }

    func test_make_highlightIncludesTrailingPunctuationByDefault() {
        let geometry = CotabbyTestFixtures.overlayGeometry()
        let layout = MirrorOverlayLayout.make(
            suggestion: "you? me",
            geometry: geometry,
            visibleFrame: screen,
            showsAcceptanceHint: false,
            reason: .userPreference
        )

        XCTAssertEqual(layout.highlightedPrefix, "you?")
    }

    func test_make_highlightExcludesTrailingPunctuationWhenSettingOff() {
        let geometry = CotabbyTestFixtures.overlayGeometry()
        let layout = MirrorOverlayLayout.make(
            suggestion: "you? me",
            geometry: geometry,
            visibleFrame: screen,
            showsAcceptanceHint: false,
            autoAcceptTrailingPunctuation: false,
            reason: .userPreference
        )

        // Matches the accept-word chunk: with the setting off, trailing punctuation is its own part,
        // so the highlight stops before it.
        XCTAssertEqual(layout.highlightedPrefix, "you")
    }

    // MARK: - Direction passthrough

    func test_make_preservesRightToLeftFlag() {
        let geometry = CotabbyTestFixtures.overlayGeometry(isRightToLeft: true)
        let layout = MirrorOverlayLayout.make(
            suggestion: "اختبار",
            geometry: geometry,
            visibleFrame: screen,
            showsAcceptanceHint: true,
            reason: .userPreference
        )

        XCTAssertTrue(layout.isRightToLeft)
    }

    // MARK: - Acceptance-hint reservation

    func test_make_widerCardWhenAcceptanceHintEnabled() {
        let geometry = CotabbyTestFixtures.overlayGeometry()
        let withHint = MirrorOverlayLayout.make(
            suggestion: "abc",
            geometry: geometry,
            visibleFrame: screen,
            showsAcceptanceHint: true,
            reason: .userPreference
        )
        let withoutHint = MirrorOverlayLayout.make(
            suggestion: "abc",
            geometry: geometry,
            visibleFrame: screen,
            showsAcceptanceHint: false,
            reason: .userPreference
        )

        XCTAssertGreaterThan(
            withHint.panelFrame.width,
            withoutHint.panelFrame.width,
            "Reserving room for the keycap should widen the card"
        )
    }
}
