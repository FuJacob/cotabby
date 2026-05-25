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
        let normalized = suggestion.replacingOccurrences(of: "\r", with: "")
        guard !normalized.isEmpty else {
            lastErrorMessage = "Suggestion was empty."
            CotabbyLogger.suggestion.warning("Insertion skipped: suggestion was empty after normalization")
            return false
        }

        guard let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            lastErrorMessage = "Unable to create a synthetic keyboard event."
            CotabbyLogger.suggestion.error("Failed to create synthetic keyboard events for insertion")
            return false
        }

        let utf16CodeUnits = Array(normalized.utf16)
        suppressionController.registerSyntheticInsertion(expectedKeyDownCount: 1)
        keyDownEvent.keyboardSetUnicodeString(stringLength: utf16CodeUnits.count, unicodeString: utf16CodeUnits)
        keyUpEvent.keyboardSetUnicodeString(stringLength: utf16CodeUnits.count, unicodeString: utf16CodeUnits)
        keyDownEvent.post(tap: .cghidEventTap)
        keyUpEvent.post(tap: .cghidEventTap)
        lastErrorMessage = nil
        CotabbyLogger.suggestion.debug("Inserted \(normalized.count) characters via synthetic keystroke")
        return true
    }
}

extension SuggestionInserter: SuggestionInserting {}
