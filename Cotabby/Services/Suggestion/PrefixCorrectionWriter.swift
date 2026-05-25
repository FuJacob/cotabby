import ApplicationServices
import Foundation
import Logging

/// File overview:
/// Performs the synthetic-event write that replaces a user's typed prefix with a corrected
/// version. Mirrors `SuggestionInserter`'s pattern: post raw CGEvents directly to the HID
/// event tap and register the expected key-down count with `InputSuppressionController`
/// so the global input monitor ignores its own writes.
///
/// Write strategy: backspace × original-length, then a single Unicode keystroke for the
/// corrected text. This is the "fake delete all, retype" approach — simple, app-agnostic,
/// and avoids the diff/arrow-key bookkeeping that an in-place edit would require. The
/// coordinator gates against very long prefixes so the backspace burst stays bounded.
@MainActor
final class PrefixCorrectionWriter {
    private static let backspaceVirtualKey: CGKeyCode = 51 // kVK_Delete

    private let suppressionController: InputSuppressionController

    init(suppressionController: InputSuppressionController) {
        self.suppressionController = suppressionController
    }

    /// Deletes the last `originalLength` graphemes from the focused field and types
    /// `correctedPrefix` in their place. Returns false if any synthetic event could not be
    /// created or if the inputs are degenerate.
    func replacePrefix(originalLength: Int, with correctedPrefix: String) -> Bool {
        let normalized = correctedPrefix.replacingOccurrences(of: "\r", with: "")
        guard originalLength > 0, !normalized.isEmpty else {
            CotabbyLogger.suggestion.warning("Prefix-correction write skipped: empty input")
            return false
        }

        // The unicode keystroke event counts as one key-down. Total suppression budget is the
        // backspace burst plus that one event.
        let expectedKeyDowns = originalLength + 1
        suppressionController.registerSyntheticInsertion(expectedKeyDownCount: expectedKeyDowns)

        for _ in 0..<originalLength {
            guard postBackspace() else {
                CotabbyLogger.suggestion.error("Prefix-correction write aborted: backspace event creation failed")
                return false
            }
        }

        guard postUnicodeString(normalized) else {
            CotabbyLogger.suggestion.error("Prefix-correction write aborted: unicode event creation failed")
            return false
        }

        CotabbyLogger.suggestion.debug(
            "Prefix-correction wrote: deleted=\(originalLength) chars, typed=\(normalized.count) chars"
        )
        return true
    }

    // MARK: - Event posting

    private func postBackspace() -> Bool {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: Self.backspaceVirtualKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: Self.backspaceVirtualKey, keyDown: false)
        else {
            return false
        }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func postUnicodeString(_ text: String) -> Bool {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else {
            return false
        }
        let utf16 = Array(text.utf16)
        keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
