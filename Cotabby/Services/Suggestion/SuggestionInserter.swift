import ApplicationServices
import Foundation
import Logging

/// File overview:
/// Commits accepted suggestions back into the host app by synthesizing Unicode keyboard events.
/// This keeps acceptance simple and app-agnostic, while pairing with suppression to avoid loops.
///
/// `insert(_:)` types a continuation. `replace(deletingUTF16Count:with:)` first deletes a run of
/// already-typed characters (the `:query` the user typed before the emoji picker) and then types the
/// replacement, which the emoji picker uses to swap `:smile` for its glyph.
@MainActor
final class SuggestionInserter {
    private let suppressionController: InputSuppressionController

    private(set) var lastErrorMessage: String?

    /// Virtual key code for Delete/Backspace. Posting these at the HID level deletes one UTF-16 unit
    /// of already-typed text per pair, which is how the picker removes the literal `:query` run.
    private static let backspaceKeyCode: CGKeyCode = 0x33

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
        // Tag the synthetic events so both taps ignore them by identity. The observer also has a
        // countdown, but the consuming accept tap relies on this marker because these events arrive
        // with the placeholder `virtualKey: 0`, which would otherwise match an accept key bound to
        // keyCode 0.
        suppressionController.markSynthetic(keyDownEvent)
        suppressionController.markSynthetic(keyUpEvent)
        keyDownEvent.keyboardSetUnicodeString(stringLength: utf16CodeUnits.count, unicodeString: utf16CodeUnits)
        keyUpEvent.keyboardSetUnicodeString(stringLength: utf16CodeUnits.count, unicodeString: utf16CodeUnits)
        keyDownEvent.post(tap: .cghidEventTap)
        keyUpEvent.post(tap: .cghidEventTap)
        lastErrorMessage = nil
        CotabbyLogger.suggestion.debug("Inserted \(normalized.count) characters via synthetic keystroke")
        return true
    }

    /// Deletes `deletingUTF16Count` already-typed UTF-16 units, then types `text`. Used by the emoji
    /// picker to replace the literal `:query` (or `:query:`) run with the chosen glyph.
    ///
    /// All synthetic events are built first, then registered for suppression in a single call, then
    /// posted. Building before registering means a failed event allocation never leaves a phantom
    /// suppression token that would swallow the user's next real keystroke. Registering the whole
    /// burst once means every backspace and the insertion keydown fall inside one suppression window,
    /// so none of our own deletes are re-observed as user typing.
    func replace(deletingUTF16Count: Int, with text: String) -> Bool {
        let plan = SyntheticReplacePlanner.plan(deletingUTF16Count: deletingUTF16Count, text: text)
        guard !plan.isNoop else {
            lastErrorMessage = nil
            return true
        }

        var events: [CGEvent] = []
        events.reserveCapacity(plan.backspaceCount * 2 + 2)

        for _ in 0..<plan.backspaceCount {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: Self.backspaceKeyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: Self.backspaceKeyCode, keyDown: false) else {
                lastErrorMessage = "Unable to create a synthetic delete event."
                CotabbyLogger.suggestion.error("Replace failed: could not create delete events")
                return false
            }
            events.append(down)
            events.append(up)
        }

        if !plan.insertUTF16.isEmpty {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                lastErrorMessage = "Unable to create a synthetic keyboard event."
                CotabbyLogger.suggestion.error("Replace failed: could not create insertion events")
                return false
            }
            down.keyboardSetUnicodeString(stringLength: plan.insertUTF16.count, unicodeString: plan.insertUTF16)
            up.keyboardSetUnicodeString(stringLength: plan.insertUTF16.count, unicodeString: plan.insertUTF16)
            events.append(down)
            events.append(up)
        }

        // Tag every synthetic event so the consuming accept tap ignores them by identity, the same way
        // `insert(_:)` does. The insertion event uses the placeholder `virtualKey: 0`, which would
        // otherwise match an accept key bound to keyCode 0 and make the tap swallow our own glyph.
        for event in events {
            suppressionController.markSynthetic(event)
        }
        suppressionController.registerSyntheticInsertion(expectedKeyDownCount: plan.totalKeyDownCount)
        for event in events {
            event.post(tap: .cghidEventTap)
        }

        lastErrorMessage = nil
        CotabbyLogger.suggestion.debug(
            "Replaced \(plan.backspaceCount) unit(s) with \(plan.insertUTF16.count)-unit text via synthetic keystrokes"
        )
        return true
    }
}

/// The synthetic key plan for a replace operation, kept pure so the accounting (how many backspaces,
/// how many suppression tokens) is unit testable without allocating CoreGraphics events. App-hosted
/// macOS tests can crash in CGEvent allocation/teardown, so the value-level math lives here.
struct SyntheticReplacePlan: Equatable {
    let backspaceCount: Int
    let insertUTF16: [UInt16]

    /// Number of keydown events the observer tap will see, and therefore the number of suppression
    /// tokens to arm. The Unicode insertion is a single keydown regardless of how many UTF-16 units
    /// it carries; keyups are a different event type and are not counted.
    var totalKeyDownCount: Int {
        backspaceCount + (insertUTF16.isEmpty ? 0 : 1)
    }

    var isNoop: Bool {
        backspaceCount == 0 && insertUTF16.isEmpty
    }
}

enum SyntheticReplacePlanner {
    static func plan(deletingUTF16Count: Int, text: String) -> SyntheticReplacePlan {
        let normalized = text.replacingOccurrences(of: "\r", with: "")
        return SyntheticReplacePlan(
            backspaceCount: max(deletingUTF16Count, 0),
            insertUTF16: Array(normalized.utf16)
        )
    }
}

extension SuggestionInserter: SuggestionInserting {}
extension SuggestionInserter: EmojiTextInserting {}
