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
/// Within a single focus session the real line height does not grow, so we treat the smallest
/// height we have seen as the truth and clamp larger readings down to it. The baseline is keyed by
/// `FocusTracker`'s `focusChangeSequence`, so switching fields — or leaving and re-entering the same
/// field — starts a fresh measurement instead of inheriting a stale ceiling.
///
/// This intentionally biases toward the smaller reading: an over-tall fallback is the observed
/// failure mode, and the downstream `minimumGhostFontSize` floor bounds how small a spurious low
/// reading can make the text.
struct GhostFontSizeStabilizer {
    private var sessionKey: UInt64?
    private var minCaretHeight: CGFloat?

    /// Returns the caret height to derive font size from: the running per-session minimum.
    ///
    /// Non-positive heights (empty rects) pass through untouched so a transient bad poll can't pin
    /// the session minimum to zero and force every later suggestion to the font-size floor.
    mutating func stabilizedCaretHeight(_ caretHeight: CGFloat, focusSessionKey: UInt64) -> CGFloat {
        guard caretHeight > 0 else {
            return caretHeight
        }

        if sessionKey != focusSessionKey {
            sessionKey = focusSessionKey
            minCaretHeight = caretHeight
            return caretHeight
        }

        let stabilized = min(caretHeight, minCaretHeight ?? caretHeight)
        minCaretHeight = stabilized
        return stabilized
    }
}
