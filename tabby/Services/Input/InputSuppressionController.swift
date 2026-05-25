import Foundation
import Logging

/// File overview:
/// Tracks Tabby's own synthetic key events so inserted suggestions do not recursively trigger
/// the input-monitoring pipeline and cause bogus follow-up completions.
///
/// Think of this as a tiny "ignore my own write" guard. When Tabby injects accepted text back into
/// the focused app, the global event tap would otherwise observe those synthetic key events and
/// treat them like fresh user typing.
@MainActor
final class InputSuppressionController {
    private var remainingKeyDownSuppressions = 0
    private var suppressionExpiry = Date.distantPast

    /// Arms a short-lived suppression window for the synthetic keydown events Tabby is about to post.
    func registerSyntheticInsertion(expectedKeyDownCount: Int) {
        remainingKeyDownSuppressions = max(expectedKeyDownCount, 0)
        suppressionExpiry = Date().addingTimeInterval(1.0)
        TabbyLogger.app.trace("Suppression armed for \(expectedKeyDownCount) synthetic key event(s)")
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
}
