import AppKit
import CoreGraphics
import Foundation

/// Pure layout math for the mirror-overlay rendering mode.
///
/// Mirror mode is reached when the host's caret geometry is unreliable, so this helper does not
/// anchor to the caret rect for positioning — it anchors to the input field's frame and falls back
/// to the caret rect only when the field frame is missing. That ordering is the opposite of the
/// inline ghost layout, which trusts the caret rect first.
///
/// Layout decisions live here as a pure value type so `OverlayController` can stay focused on
/// AppKit window plumbing and the rules below stay easy to test without spinning up SwiftUI.
struct MirrorOverlayLayout: Equatable {
    /// Final panel frame in screen coordinates. The caller passes this directly to `NSPanel.setFrame`.
    let panelFrame: CGRect

    /// Fixed font size for the suggestion text. Mirror mode deliberately ignores the caret-derived
    /// font sizing used by inline ghost text. The whole reason we are in mirror mode is that the
    /// caret rect (and therefore its height) is untrustworthy, so deriving font size from it would
    /// just propagate the same unreliable signal into the UI.
    let fontSize: CGFloat

    /// The suggestion to render. Whitespace collapsed for single-line display.
    let suggestionText: String

    /// The leading run of `suggestionText` that the next accept-word keypress will insert, so the
    /// card can highlight it as the word being completed. Always a prefix of `suggestionText` (empty
    /// when there is nothing to highlight) so the renderer can split safely on its length.
    let highlightedPrefix: String

    /// Reading direction for the host text. The card lays out left-to-right even in RTL hosts so the
    /// "[hint] [Tab]" pattern stays readable; the field is repeated as `isRightToLeft` for callers
    /// that need to flip secondary chrome (Phase 3 prefix hint will use this).
    let isRightToLeft: Bool

    /// Which trigger surfaced this presentation. Plumbed through purely for diagnostics so the
    /// debug overlay can show why mirror mode is up.
    let reason: CompletionRenderMode.MirrorReason

    private enum Metrics {
        /// Fixed font size for the suggestion in the card. Sized for legibility at typical viewing
        /// distance, not to match the host editor (mirror is explicitly a preview, not a forgery).
        static let fontSize: CGFloat = 13

        /// Vertical gap between the bottom of the input field (or caret rect) and the top of the
        /// card. Large enough that the card does not look like it is part of the field.
        static let anchorGap: CGFloat = 8

        /// Internal padding inside the card around the text + keycap row.
        static let horizontalPadding: CGFloat = 10
        static let verticalPadding: CGFloat = 6

        /// Estimated keycap pill width (matches GhostKeycap's roughly 28pt label + spacing). Used to
        /// reserve room for the acceptance hint when computing card width.
        static let keycapReservation: CGFloat = 36

        /// Width budget caps. We do not want a card that spans the whole monitor for a long
        /// completion; clamp to a comfortable reading width with horizontal scrolling-style ellipsis
        /// handled by SwiftUI lineLimit.
        static let maxCardWidth: CGFloat = 520
        static let minCardWidth: CGFloat = 120

        /// Distance the card must keep from screen edges so it never clips against the menu bar or
        /// dock. The visibleFrame already excludes those, but a small inset still looks more
        /// intentional than touching the edge.
        static let screenMargin: CGFloat = 12

        /// Vertical offset used when only the caret rect is available (no input frame). Spans about
        /// one line height so the card sits just below the caret line rather than on top of it.
        static let caretFallbackVerticalOffset: CGFloat = 22
    }

    /// Computes the layout for one presentation.
    ///
    /// `geometry.inputFrameRect` is the preferred anchor. When it is nil the card falls back to a
    /// fixed offset below the caret rect — worse, but at least directionally correct. `visibleFrame`
    /// is the target screen's visible region and is used to clamp the card on-screen.
    static func make(
        suggestion: String,
        geometry: SuggestionOverlayGeometry,
        visibleFrame: CGRect,
        showsAcceptanceHint: Bool,
        autoAcceptTrailingPunctuation: Bool = true,
        reason: CompletionRenderMode.MirrorReason
    ) -> MirrorOverlayLayout {
        let normalizedSuggestion = normalizedDisplayText(suggestion)
        let highlightedPrefix = highlightedAcceptancePrefix(
            in: normalizedSuggestion,
            autoAcceptTrailingPunctuation: autoAcceptTrailingPunctuation
        )
        let measuredTextWidth = measuredWidth(of: normalizedSuggestion, fontSize: Metrics.fontSize)
        let keycapReservation = showsAcceptanceHint ? Metrics.keycapReservation : 0

        // Reserve the keycap on top of the text width, not inside the min/max clamp. Otherwise a
        // short suggestion (measured width below `minCardWidth`) gets the same card as one with the
        // hint disabled because the minimum floor absorbs the reservation.
        let textBudget = max(0, Metrics.maxCardWidth - keycapReservation)
        let textContentWidth = min(textBudget, max(Metrics.minCardWidth, measuredTextWidth))
        let contentWidth = textContentWidth + keycapReservation
        let cardWidth = contentWidth + (Metrics.horizontalPadding * 2)
        let cardHeight = ceil(Metrics.fontSize * 1.6) + (Metrics.verticalPadding * 2)

        let anchorTopY = computeAnchorTopY(geometry: geometry, reason: reason)
        let anchorCenterX = computeAnchorCenterX(geometry: geometry)

        var originX = anchorCenterX - (cardWidth / 2)
        // Card sits BELOW the field/caret. AppKit screen coordinates are bottom-up, so subtracting
        // the card height from the anchor's bottom edge places the card just under the anchor line.
        var originY = anchorTopY - cardHeight

        // Clamp to the visible frame so the card never disappears off-screen for hosts near edges.
        let minX = visibleFrame.minX + Metrics.screenMargin
        let maxX = visibleFrame.maxX - Metrics.screenMargin - cardWidth
        if maxX >= minX {
            originX = min(max(originX, minX), maxX)
        } else {
            originX = minX
        }

        let minY = visibleFrame.minY + Metrics.screenMargin
        let maxY = visibleFrame.maxY - Metrics.screenMargin - cardHeight
        if maxY >= minY {
            originY = min(max(originY, minY), maxY)
        } else {
            originY = minY
        }

        let panelFrame = CGRect(
            x: originX,
            y: originY,
            width: cardWidth,
            height: cardHeight
        ).integral

        return MirrorOverlayLayout(
            panelFrame: panelFrame,
            fontSize: Metrics.fontSize,
            suggestionText: normalizedSuggestion,
            highlightedPrefix: highlightedPrefix,
            isRightToLeft: geometry.isRightToLeft,
            reason: reason
        )
    }

    /// The Y coordinate the card sits *under*. In AppKit's bottom-up coordinate system this is the
    /// bottom edge of the anchor minus the gap.
    ///
    /// The anchor choice depends on *why* mirror mode is active:
    ///
    /// - `.caretGeometryEstimated` means the host did not expose any of the trusted caret paths, so
    ///   the caret rect itself is unreliable. We anchor to the input field rect when available
    ///   because the field rect stays stable even when the caret estimate drifts.
    /// - `.userPreference`, `.perAppOverride`, and `.caretMidLine` all mean the caret geometry is
    ///   trustworthy (`.exact` or `.derived`); the card is up because the user pinned popup mode or
    ///   the caret is mid-line. Anchoring to the field rect would waste the precise caret signal and
    ///   land the card far below where the eye is, so we anchor to the caret rect instead, with the
    ///   input field as a safety net only for the degenerate case where the caret rect is empty.
    private static func computeAnchorTopY(
        geometry: SuggestionOverlayGeometry,
        reason: CompletionRenderMode.MirrorReason
    ) -> CGFloat {
        switch reason {
        case .caretGeometryEstimated:
            if let inputFrame = geometry.inputFrameRect?.standardized, !inputFrame.isEmpty {
                return inputFrame.minY - Metrics.anchorGap
            }
            // Caret-rect fallback uses the larger offset because in `.estimated` we treat the caret
            // height as unreliable; the extra slack keeps the card from overlapping the typed line.
            return geometry.caretRect.minY - Metrics.caretFallbackVerticalOffset

        case .userPreference, .perAppOverride, .caretMidLine:
            // Caret geometry is trustworthy in these cases. Sit just under the caret line so the
            // popup tracks the cursor like the inline ghost does, instead of floating below the
            // entire field.
            if !geometry.caretRect.isEmpty {
                return geometry.caretRect.minY - Metrics.anchorGap
            }
            if let inputFrame = geometry.inputFrameRect?.standardized, !inputFrame.isEmpty {
                return inputFrame.minY - Metrics.anchorGap
            }
            return geometry.caretRect.minY - Metrics.caretFallbackVerticalOffset
        }
    }

    /// Horizontal center the card aligns to. Prefer the caret's X because the user's eye is already
    /// near the caret; only fall back to the field center if the caret rect looks degenerate.
    private static func computeAnchorCenterX(geometry: SuggestionOverlayGeometry) -> CGFloat {
        if geometry.caretRect.width > 0 || geometry.caretRect.minX > 0 {
            return geometry.caretRect.midX
        }
        if let inputFrame = geometry.inputFrameRect?.standardized, !inputFrame.isEmpty {
            return inputFrame.midX
        }
        return geometry.caretRect.midX
    }

    /// The leading run of `suggestionText` the accept-word key will insert next, reused from the real
    /// acceptance chunker (`SuggestionSessionReconciler.nextAcceptanceChunk`) so the highlight matches
    /// exactly what one Tab takes, including the trailing-punctuation policy. Guarded to be a prefix of
    /// `suggestionText` so the renderer's split-by-length is always safe; returns "" otherwise.
    static func highlightedAcceptancePrefix(
        in suggestionText: String,
        autoAcceptTrailingPunctuation: Bool
    ) -> String {
        let chunk = SuggestionSessionReconciler.nextAcceptanceChunk(
            from: suggestionText,
            autoAcceptTrailingPunctuation: autoAcceptTrailingPunctuation
        )
        return suggestionText.hasPrefix(chunk) ? chunk : ""
    }

    /// Collapses internal whitespace and trims edges so the card never renders a multi-line block.
    /// Mirror mode is single-line by design — the inline ghost is what handles multi-line wrapping.
    private static func normalizedDisplayText(_ text: String) -> String {
        let collapsed = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed
    }

    private static func measuredWidth(of text: String, fontSize: CGFloat) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize)
        ]
        return (text as NSString).size(withAttributes: attributes).width
    }
}
