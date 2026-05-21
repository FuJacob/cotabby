import ApplicationServices
import Foundation

/// File overview:
/// Commits accepted suggestions back into the host app by synthesizing Unicode keyboard events.
/// This keeps acceptance simple and app-agnostic, while pairing with suppression to avoid loops.
///
/// Inserts the accepted suggestion by synthesizing a single Unicode keyboard event.
/// This is simpler than AX field mutation for a first slice, but it is also more brittle.
@MainActor
final class SuggestionInserter {
    private enum DraftTyping {
        static let chunkCharacterCount = 8
        static let delayNanoseconds: UInt64 = 12_000_000
        static let suppressionDuration: TimeInterval = 3.0
    }

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

        return postUnicodeKeyboardEvent(normalized, suppressionDuration: 1.0)
    }

    /// Types a Compose draft in small synthetic chunks. This keeps the host app on the normal text
    /// input path while making cancellation and focus checks possible between chunks.
    func typeDraft(
        _ draft: String,
        shouldContinue: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let normalized = draft.replacingOccurrences(of: "\r", with: "")
        guard !normalized.isEmpty else {
            lastErrorMessage = "Compose draft was empty."
            return false
        }

        for chunk in Self.chunks(
            from: normalized,
            maxCharacters: DraftTyping.chunkCharacterCount
        ) {
            guard !Task.isCancelled, shouldContinue() else {
                lastErrorMessage = "Compose typing was cancelled because focus changed."
                return false
            }

            guard postUnicodeKeyboardEvent(
                chunk,
                suppressionDuration: DraftTyping.suppressionDuration
            ) else {
                return false
            }

            try? await Task.sleep(nanoseconds: DraftTyping.delayNanoseconds)
        }

        lastErrorMessage = nil
        return true
    }

    private func postUnicodeKeyboardEvent(
        _ text: String,
        suppressionDuration: TimeInterval
    ) -> Bool {
        guard let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else {
            lastErrorMessage = "Unable to create a synthetic keyboard event."
            return false
        }

        let utf16CodeUnits = Array(text.utf16)
        suppressionController.registerSyntheticInsertion(
            expectedKeyDownCount: 1,
            duration: suppressionDuration
        )
        keyDownEvent.keyboardSetUnicodeString(stringLength: utf16CodeUnits.count, unicodeString: utf16CodeUnits)
        keyUpEvent.keyboardSetUnicodeString(stringLength: utf16CodeUnits.count, unicodeString: utf16CodeUnits)
        keyDownEvent.post(tap: .cghidEventTap)
        keyUpEvent.post(tap: .cghidEventTap)
        lastErrorMessage = nil
        return true
    }

    private static func chunks(from text: String, maxCharacters: Int) -> [String] {
        guard maxCharacters > 0 else {
            return [text]
        }

        var chunks: [String] = []
        var currentIndex = text.startIndex

        while currentIndex < text.endIndex {
            let nextIndex = text.index(
                currentIndex,
                offsetBy: maxCharacters,
                limitedBy: text.endIndex
            ) ?? text.endIndex
            chunks.append(String(text[currentIndex..<nextIndex]))
            currentIndex = nextIndex
        }

        return chunks
    }
}

extension SuggestionInserter: SuggestionInserting {}
