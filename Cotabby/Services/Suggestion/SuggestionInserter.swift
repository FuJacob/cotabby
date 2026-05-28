import ApplicationServices
import Foundation
import Logging

/// File overview:
/// Commits accepted suggestions back into the host app by synthesizing Unicode keyboard events.
/// This keeps acceptance simple and app-agnostic, while pairing with suppression to avoid loops.
///
/// Inserts the accepted suggestion by synthesizing a single Unicode keyboard event.
/// This is simpler than AX field mutation for a first slice, but it is also more brittle.
@MainActor
final class SuggestionInserter {
    private let suppressionController: InputSuppressionController

    private(set) var lastErrorMessage: String?

    init(suppressionController: InputSuppressionController) {
        self.suppressionController = suppressionController
    }

    /// Posts a Unicode keydown/keyup pair for the accepted suggestion and reports any insertion failure.
    func insert(_ suggestion: String) -> Bool {
        insert(suggestion, replacingLastCharacters: 0)
    }

    /// Replaces the trailing `deleteCount` characters of the host field with `suggestion`. The
    /// implementation:
    ///   1. Arms `InputSuppressionController` for `deleteCount + 1` synthetic key-down events so
    ///      the global event tap ignores its own writes during the replacement.
    ///   2. Posts `deleteCount` backspace events using `kVK_Delete` (virtual key 51).
    ///   3. Posts one Unicode keydown/keyup pair carrying the replacement string.
    ///
    /// We synthesize backspaces rather than mutating the AX value directly so the field's own
    /// undo stack, IME state, and rich-text formatting machinery all see the change as if the
    /// user typed it themselves — that matches how `insert` already behaves for forward inserts
    /// and avoids opening a second, app-specific failure mode.
    func insert(_ suggestion: String, replacingLastCharacters deleteCount: Int) -> Bool {
        let normalized = suggestion.replacingOccurrences(of: "\r", with: "")
        guard !normalized.isEmpty else {
            lastErrorMessage = "Suggestion was empty."
            CotabbyLogger.suggestion.warning("Insertion skipped: suggestion was empty after normalization")
            return false
        }

        let backspaceCount = max(deleteCount, 0)
        // Arm suppression to cover every synthetic keydown we're about to post: one per backspace
        // plus one for the Unicode insert. The expiry window (1s, set inside the controller) is
        // wide enough that the whole sequence completes before suppression decays.
        suppressionController.registerSyntheticInsertion(expectedKeyDownCount: backspaceCount + 1)

        for _ in 0..<backspaceCount {
            guard let downEvent = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(51), keyDown: true),
                  let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(51), keyDown: false) else {
                lastErrorMessage = "Unable to create a synthetic backspace event."
                CotabbyLogger.suggestion.error("Failed to create synthetic backspace event for correction insertion")
                return false
            }
            downEvent.post(tap: .cghidEventTap)
            upEvent.post(tap: .cghidEventTap)
        }

        guard let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            lastErrorMessage = "Unable to create a synthetic keyboard event."
            CotabbyLogger.suggestion.error("Failed to create synthetic keyboard events for insertion")
            return false
        }

        let utf16CodeUnits = Array(normalized.utf16)
        keyDownEvent.keyboardSetUnicodeString(stringLength: utf16CodeUnits.count, unicodeString: utf16CodeUnits)
        keyUpEvent.keyboardSetUnicodeString(stringLength: utf16CodeUnits.count, unicodeString: utf16CodeUnits)
        keyDownEvent.post(tap: .cghidEventTap)
        keyUpEvent.post(tap: .cghidEventTap)
        lastErrorMessage = nil
        if backspaceCount > 0 {
            CotabbyLogger.suggestion.debug(
                "Replaced last \(backspaceCount) characters with \(normalized.count) characters via synthetic keystrokes"
            )
        } else {
            CotabbyLogger.suggestion.debug("Inserted \(normalized.count) characters via synthetic keystroke")
        }
        return true
    }
}

extension SuggestionInserter: SuggestionInserting {}
