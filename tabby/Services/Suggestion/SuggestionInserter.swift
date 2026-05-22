import ApplicationServices
import Foundation

/// File overview:
/// Commits accepted suggestions back into the host app by synthesizing Unicode keyboard events.
/// This keeps acceptance simple and app-agnostic, while pairing with suppression to avoid loops.
///
/// Inserts accepted text by synthesizing keyboard events.
///
/// Normal autocomplete uses a single Unicode insertion. Spell correction first sends Backspace for
/// the misspelled token, then inserts the corrected spelling. We use keyboard events instead of AX
/// value mutation so the host app keeps ownership of undo grouping, input-method behavior, and text
/// field-specific validation.
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
            return false
        }

        guard let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            lastErrorMessage = "Unable to create a synthetic keyboard event."
            return false
        }

        let utf16CodeUnits = Array(normalized.utf16)
        suppressionController.registerSyntheticInsertion(expectedKeyDownCount: 1)
        keyDownEvent.keyboardSetUnicodeString(stringLength: utf16CodeUnits.count, unicodeString: utf16CodeUnits)
        keyUpEvent.keyboardSetUnicodeString(stringLength: utf16CodeUnits.count, unicodeString: utf16CodeUnits)
        keyDownEvent.post(tap: .cghidEventTap)
        keyUpEvent.post(tap: .cghidEventTap)
        lastErrorMessage = nil
        return true
    }

    /// Replaces the token immediately before the caret.
    ///
    /// This intentionally supports only backward replacement. Tabby's focus snapshots tell us the
    /// text before the caret reliably enough to identify the token, but they do not give every app a
    /// safe editable text range API. Backspace-plus-insert is narrower and matches user-visible
    /// behavior in more host applications.
    func replacePreviousCharacters(count: Int, with replacement: String) -> Bool {
        let deleteCount = max(count, 0)
        guard deleteCount > 0 else {
            lastErrorMessage = "Replacement did not specify characters to delete."
            return false
        }

        let normalizedReplacement = replacement.replacingOccurrences(of: "\r", with: "")
        guard !normalizedReplacement.isEmpty else {
            lastErrorMessage = "Replacement text was empty."
            return false
        }

        suppressionController.registerSyntheticInsertion(expectedKeyDownCount: deleteCount + 1)

        for _ in 0 ..< deleteCount {
            guard postBackspace() else {
                lastErrorMessage = "Unable to create a synthetic Backspace event."
                return false
            }
        }

        guard postUnicodeInsertion(normalizedReplacement) else {
            lastErrorMessage = "Unable to create a synthetic keyboard event."
            return false
        }

        lastErrorMessage = nil
        return true
    }

    private func postUnicodeInsertion(_ text: String) -> Bool {
        guard let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            return false
        }

        let utf16CodeUnits = Array(text.utf16)
        keyDownEvent.keyboardSetUnicodeString(stringLength: utf16CodeUnits.count, unicodeString: utf16CodeUnits)
        keyUpEvent.keyboardSetUnicodeString(stringLength: utf16CodeUnits.count, unicodeString: utf16CodeUnits)
        keyDownEvent.post(tap: .cghidEventTap)
        keyUpEvent.post(tap: .cghidEventTap)
        return true
    }

    private func postBackspace() -> Bool {
        let backspaceKeyCode: CGKeyCode = 51
        guard let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: backspaceKeyCode, keyDown: true),
              let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: backspaceKeyCode, keyDown: false) else {
            return false
        }

        keyDownEvent.post(tap: .cghidEventTap)
        keyUpEvent.post(tap: .cghidEventTap)
        return true
    }
}

extension SuggestionInserter: SuggestionInserting {}
