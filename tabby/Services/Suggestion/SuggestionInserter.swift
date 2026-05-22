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
    typealias SuppressionRegistrar = (Int) -> Void
    typealias KeyboardEventFactory = (CGKeyCode, Bool) -> CGEvent?
    typealias EventPoster = (CGEvent) -> Void

    private let registerSuppression: SuppressionRegistrar
    private let makeKeyboardEvent: KeyboardEventFactory
    private let postEvent: EventPoster

    private(set) var lastErrorMessage: String?

    convenience init(suppressionController: InputSuppressionController) {
        self.init(
            registerSuppression: { expectedKeyDownCount in
                suppressionController.registerSyntheticInsertion(
                    expectedKeyDownCount: expectedKeyDownCount
                )
            },
            makeKeyboardEvent: { keyCode, keyDown in
                CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown)
            },
            postEvent: { event in
                event.post(tap: .cghidEventTap)
            }
        )
    }

    init(
        registerSuppression: @escaping SuppressionRegistrar,
        makeKeyboardEvent: @escaping KeyboardEventFactory,
        postEvent: @escaping EventPoster
    ) {
        self.registerSuppression = registerSuppression
        self.makeKeyboardEvent = makeKeyboardEvent
        self.postEvent = postEvent
    }

    /// Posts a Unicode keydown/keyup pair for the accepted suggestion and reports any insertion failure.
    func insert(_ suggestion: String) -> Bool {
        let normalized = suggestion.replacingOccurrences(of: "\r", with: "")
        guard !normalized.isEmpty else {
            lastErrorMessage = "Suggestion was empty."
            return false
        }

        guard let events = preparedUnicodeInsertionEvents(for: normalized) else {
            lastErrorMessage = "Unable to create a synthetic keyboard event."
            return false
        }

        registerSuppression(1)
        postPreparedEvents(events)
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

        var bufferedEvents: [CGEvent] = []
        bufferedEvents.reserveCapacity((deleteCount + 1) * 2)

        for _ in 0 ..< deleteCount {
            guard let backspaceEvents = preparedBackspaceEvents() else {
                lastErrorMessage = "Unable to create a synthetic Backspace event."
                return false
            }
            bufferedEvents.append(contentsOf: backspaceEvents)
        }

        guard let replacementEvents = preparedUnicodeInsertionEvents(for: normalizedReplacement) else {
            lastErrorMessage = "Unable to create a synthetic keyboard event."
            return false
        }
        bufferedEvents.append(contentsOf: replacementEvents)

        // Only arm suppression after the full replacement plan exists. Otherwise a late event
        // creation failure could leave suppression tokens armed with no matching synthetic events.
        registerSuppression(deleteCount + 1)
        postPreparedEvents(bufferedEvents)
        lastErrorMessage = nil
        return true
    }

    private func preparedUnicodeInsertionEvents(for text: String) -> [CGEvent]? {
        guard let keyDownEvent = makeKeyboardEvent(0, true),
              let keyUpEvent = makeKeyboardEvent(0, false)
        else {
            return nil
        }

        let utf16CodeUnits = Array(text.utf16)
        keyDownEvent.keyboardSetUnicodeString(stringLength: utf16CodeUnits.count, unicodeString: utf16CodeUnits)
        keyUpEvent.keyboardSetUnicodeString(stringLength: utf16CodeUnits.count, unicodeString: utf16CodeUnits)
        return [keyDownEvent, keyUpEvent]
    }

    private func preparedBackspaceEvents() -> [CGEvent]? {
        let backspaceKeyCode: CGKeyCode = 51
        guard let keyDownEvent = makeKeyboardEvent(backspaceKeyCode, true),
              let keyUpEvent = makeKeyboardEvent(backspaceKeyCode, false)
        else {
            return nil
        }

        return [keyDownEvent, keyUpEvent]
    }

    private func postPreparedEvents(_ events: [CGEvent]) {
        for event in events {
            postEvent(event)
        }
    }
}

extension SuggestionInserter: SuggestionInserting {}
