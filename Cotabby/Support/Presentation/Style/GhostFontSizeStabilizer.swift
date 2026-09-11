import CoreGraphics
import Foundation

/// Floors ghost-text size to the smallest caret line height observed during one focus session.
///
/// AX caret geometry is eventually consistent and app-specific. The same field can yield a tight
/// line-height caret on one poll (zero-length `BoundsForRange`) and the full field-height `AXFrame`
/// fallback on the next, when the precise branches happen to fail. Because `OverlayController`
/// derives ghost font size from caret height, that fluctuation renders the suggestion comically
/// oversized whenever the coarse fallback wins a poll.
///
/// When a reading is imprecise we treat the smallest height seen this session as the truth and
/// clamp larger readings down to it. The baseline is keyed by `FocusTracker`'s
/// `focusChangeSequence`, so switching fields — or leaving and re-entering the same field — starts
/// a fresh measurement instead of inheriting a stale ceiling.
///
/// This intentionally biases toward the smaller reading: an over-tall fallback is the observed
/// failure mode, and the downstream `minimumGhostFontSize` floor bounds how small a spurious low
/// reading can make the text.
///
/// Crucially, the clamp applies *only to imprecise readings*. The flicker it defends against is
/// specifically a precise branch failing and falling back to the coarse `AXFrame` height, which is
/// reported as `.estimated`. A precise measurement (`.exact` / `.derived`) is a real line box and
/// must be honoured immediately, because the host's text can legitimately grow within one focus
/// session — changing the font size or the zoom level does exactly that without ever changing the
/// focused element. Clamping those readings made the session minimum a ratchet: a user who set
/// Word to 20pt after typing at 12pt kept a caret pinned at the old 17pt height, and ghost text
/// stayed 40% too small until focus happened to change.
struct GhostFontSizeStabilizer {
    private var sessionKey: UInt64?
    private var minCaretHeight: CGFloat?

    /// Returns the caret height to derive font size from.
    ///
    /// `isPreciseMeasurement` is true when the caret rect came from real text-range geometry rather
    /// than the coarse field-frame fallback. A precise reading is returned as-is and *becomes* the
    /// new baseline, so genuine growth (a larger font, a higher zoom) takes effect on the very next
    /// render. Only an imprecise reading is clamped down to the running minimum, which is the whole
    /// point of the type: an `AXFrame`-height fallback must not balloon the ghost text.
    ///
    /// Non-positive heights (empty rects) pass through untouched so a transient bad poll can't pin
    /// the session minimum to zero and force every later suggestion to the font-size floor.
    mutating func stabilizedCaretHeight(
        _ caretHeight: CGFloat,
        isPreciseMeasurement: Bool,
        focusSessionKey: UInt64
    ) -> CGFloat {
        guard caretHeight > 0 else {
            return caretHeight
        }

        if sessionKey != focusSessionKey {
            sessionKey = focusSessionKey
            minCaretHeight = caretHeight
            return caretHeight
        }

        // Real geometry: trust it and re-baseline, so a font-size or zoom change lands immediately.
        if isPreciseMeasurement {
            minCaretHeight = caretHeight
            return caretHeight
        }

        // Coarse `AXFrame` fallback: clamp to the session minimum so it cannot balloon the ghost.

        let stabilized = min(caretHeight, minCaretHeight ?? caretHeight)
        minCaretHeight = stabilized
        return stabilized
    }
}
