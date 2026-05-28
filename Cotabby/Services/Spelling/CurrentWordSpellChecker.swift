import AppKit
import Foundation

/// File overview:
/// Thin wrapper around `NSSpellChecker` for the typo gate. We isolate the AppKit dependency here
/// so the prediction pipeline depends on a focused, testable surface rather than `NSSpellChecker`
/// directly.
///
/// Why a wrapper at all:
/// - We need a stable per-app spell document tag so our checks don't share state with other apps.
/// - The "is this word a typo?" question has a specific NSRange-equality interpretation that we
///   want to spell out once and never get wrong.
/// - Mockability for tests later.
@MainActor
final class CurrentWordSpellChecker {
    /// Document tag identifies our "spell session" inside `NSSpellChecker.shared`. Using a unique
    /// tag avoids cross-contamination with whatever spellcheck state other apps have armed.
    private let documentTag: Int

    init() {
        documentTag = NSSpellChecker.uniqueSpellDocumentTag()
        // We don't pin a language. The shared checker picks up the system language and, with this
        // flag on, will swap as the user's text suggests a different one — useful for users who
        // code-switch between languages mid-paragraph.
        NSSpellChecker.shared.automaticallyIdentifiesLanguages = true
    }

    /// Returns true when NSSpellChecker considers the entire word misspelled. We require the
    /// returned range to cover the whole word starting at offset 0 — otherwise we'd misfire on
    /// words like "I'm" where only part of the token is flagged.
    func isTypo(_ word: String, language: String? = nil) -> Bool {
        guard !word.isEmpty else { return false }
        let misspelledRange = NSSpellChecker.shared.checkSpelling(
            of: word,
            startingAt: 0,
            language: language,
            wrap: false,
            inSpellDocumentWithTag: documentTag,
            wordCount: nil
        )
        guard misspelledRange.location == 0 else {
            return false
        }
        return misspelledRange.length == (word as NSString).length
    }

    /// Returns NSSpellChecker's own ranked corrections for the word (best first). Used as a hint
    /// to the LLM in correction mode — the model can override it when surrounding context picks
    /// a better fix. Empty array means the checker had no suggestions to offer.
    func nativeCorrections(for word: String, language: String? = nil) -> [String] {
        let fullRange = NSRange(location: 0, length: (word as NSString).length)
        let guesses = NSSpellChecker.shared.guesses(
            forWordRange: fullRange,
            in: word,
            language: language,
            inSpellDocumentWithTag: documentTag
        )
        return guesses ?? []
    }
}
