import Foundation

/// Decides whether a freshly shown ghost-text overlay should fade in rather than appear instantly.
///
/// The hard rule this protects: a fade may only play on a *genuine appearance* of the overlay, never
/// on an update to one that is already on screen. Caret repositions, streamed-token extensions, and
/// word-by-word advances all re-invoke the show path while the panel stays visible; restarting the
/// opacity animation on any of those would make stable ghost text flicker on every keystroke. The
/// `overlayWasVisible` input is the panel state captured *before* the new content is applied, so a
/// `false` value means the panel was hidden and this is a real first paint.
///
/// `reduceMotionEnabled` mirrors the system Accessibility "Reduce Motion" preference. Honoring it
/// suppresses the animation even when the user has the Cotabby toggle on, because non-essential
/// motion is exactly what that setting asks apps to drop; the suggestion still appears, just without
/// the fade. Keeping the decision in a pure function lets all three inputs be exhaustively tested
/// without standing up an `NSPanel` or AppKit animation.
enum SuggestionFadeInPolicy {
    static func shouldFadeIn(
        isEnabled: Bool,
        overlayWasVisible: Bool,
        reduceMotionEnabled: Bool
    ) -> Bool {
        guard isEnabled, !reduceMotionEnabled else {
            return false
        }
        return !overlayWasVisible
    }
}
