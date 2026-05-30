import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Tracks Cotabby's own synthetic key events so inserted suggestions do not recursively trigger
/// the input-monitoring pipeline and cause bogus follow-up completions.
///
/// Think of this as a tiny "ignore my own write" guard. When Cotabby injects accepted text back into
/// the focused app, the global event tap would otherwise observe those synthetic key events and
/// treat them like fresh user typing.
@MainActor
final class InputSuppressionController {
    private var remainingKeyDownSuppressions = 0
    private var suppressionExpiry = Date.distantPast

    /// Stamped onto Cotabby's synthetic insertion events so any tap can recognize them by identity,
    /// not just the listen-only observer's countdown. The consuming accept tap needs this: the
    /// inserter posts with `virtualKey: 0`, so if a user binds the accept key to keyCode 0 the accept
    /// tap would otherwise treat our own inserted text as accept-key presses and swallow the
    /// insertion. The value is an arbitrary sentinel; real events default this field to 0.
    static let syntheticEventUserData: Int64 = 0x436F_7461_6262_79

    /// Arms a short-lived suppression window for the synthetic keydown events Cotabby is about to post.
    func registerSyntheticInsertion(expectedKeyDownCount: Int) {
        remainingKeyDownSuppressions = max(expectedKeyDownCount, 0)
        suppressionExpiry = Date().addingTimeInterval(1.0)
        CotabbyLogger.app.trace("Suppression armed for \(expectedKeyDownCount) synthetic key event(s)")
    }

    /// Consumes one pending suppression token if the current event still falls inside the expiry window.
    /// The expiry protects against stale suppression accidentally swallowing a real later keystroke.
    func consumeIfNeeded() -> Bool {
        guard remainingKeyDownSuppressions > 0 else {
            return false
        }

        guard Date() <= suppressionExpiry else {
            remainingKeyDownSuppressions = 0
            return false
        }

        remainingKeyDownSuppressions -= 1
        return true
    }

    /// Tags an event Cotabby is about to post so taps can ignore it by identity.
    func markSynthetic(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventUserData)
    }

    /// True when the event carries Cotabby's synthetic-insertion marker.
    func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventUserData
    }
}
