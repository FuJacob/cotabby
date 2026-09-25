import CoreGraphics
import Foundation

/// Remembers a host's display scale (its zoom) for one focus session, learned from renders whose
/// caret height was a real measurement, so a later render whose caret height is synthetic can still
/// size ghost text in screen points.
///
/// Why this exists: on the `AXFrame` fallback path the caret height is a fabricated constant, so
/// `GhostFontMetrics` sizes ghost text from the point size the host reports instead. That report is
/// in document points, and a zoomed document renders it larger — Word at 200% draws its 12pt text
/// at 24pt — so an unscaled report made ghost text half the size of the user's own. A precise caret
/// seen earlier in the same field reveals the zoom, and it does not change until the user zooms,
/// at which point the next precise render re-learns it.
///
/// Owned by `OverlayController` as a plain value, with the same lifetime and keying as
/// `GhostFontSizeStabilizer`: the focused input's identity key, so a field switch starts over and
/// never inherits another host's zoom.
struct GhostHostScaleTracker {
    private var sessionKey: UInt64?
    private var scale: CGFloat?

    /// Records the scale one precise render implied. A nil scale — a render that could not measure —
    /// leaves an earlier one in place rather than erasing it.
    mutating func record(_ scale: CGFloat?, focusSessionKey: UInt64) {
        if sessionKey != focusSessionKey {
            sessionKey = focusSessionKey
            self.scale = nil
        }
        if let scale {
            self.scale = scale
        }
    }

    /// The scale learned in this focus session, or nil when none has been yet.
    func scale(forFocusSessionKey focusSessionKey: UInt64) -> CGFloat? {
        sessionKey == focusSessionKey ? scale : nil
    }
}
