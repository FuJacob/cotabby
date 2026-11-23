import Foundation

/// File overview:
/// Pure helper that pulls the trailing natural-language word out of the text before the caret.
/// `CaretWordContext.committedWord` uses it to recognize the word a typo correction may replace.
///
/// We intentionally do not lean on `NSLinguisticTagger` or `NLTokenizer` here. Both pull in language
/// detection that is overkill for the "is the cursor inside or just after a word" question. A
/// whitespace walk is faster, deterministic, and easy to reason about.
/// `nonisolated` keeps these deterministic string operations usable by boundary policy without
/// inheriting the app target's default MainActor isolation. No AppKit or shared state is touched.
nonisolated enum CurrentWordExtractor {
    /// Returns the trailing word at the cursor, or `nil` when:
    ///  - the cursor is on (or just after) whitespace (so there is no "current word"),
    ///  - the trailing token is implausible as natural language (URL, code, all-caps acronym,
    ///    digits), where `NSSpellChecker` would over-flag,
    ///  - the trailing token is too short (single-letter words are too noisy to act on).
    static func extract(from precedingText: String) -> String? {
        guard let lastCharacter = precedingText.last, !lastCharacter.isWhitespace else {
            return nil
        }

        // Walk back to the previous whitespace boundary; that is the start of the trailing word.
        var startIndex = precedingText.endIndex
        while startIndex > precedingText.startIndex {
            let prior = precedingText.index(before: startIndex)
            if precedingText[prior].isWhitespace {
                break
            }
            startIndex = prior
        }

        let word = String(precedingText[startIndex..<precedingText.endIndex])
        guard isPlausibleNaturalWord(word) else {
            return nil
        }
        return word
    }

    /// Filter out tokens that are not natural-language words so we never slap a "typo" flag onto the
    /// user's variable names, URLs, mentions, or numeric values. Keep this conservative: false
    /// negatives (we miss a real typo) are fine; false positives (we flag code as a typo) are not.
    ///
    /// A token ending in punctuation (e.g. `nmae,`) is effectively rejected downstream: the spell
    /// checker's whole-word range test does not cover the trailing punctuation, so `isTypo` returns
    /// false. That keeps the "current word being typed" model intact (we only act while the caret is
    /// adjacent to the word's letters) without special-casing punctuation here.
    private static func isPlausibleNaturalWord(_ word: String) -> Bool {
        guard word.count >= 2 else { return false }

        let codeLikeCharacters: Set<Character> = [
            "@", "/", "\\", "_", ":", ".", "#", "<", ">",
            "(", ")", "[", "]", "{", "}",
            "$", "%", "^", "*", "=", "+", "|", "~", "`"
        ]
        for character in word {
            if character.isNumber { return false }
            if codeLikeCharacters.contains(character) { return false }
        }

        // All-uppercase tokens are almost always acronyms (USA, HTTP, JSON). NSSpellChecker flags
        // many of them as typos, but correcting them is not useful here.
        let letters = word.filter { $0.isLetter }
        if !letters.isEmpty, letters.allSatisfy({ $0.isUppercase }) {
            return false
        }

        return true
    }
}

/// The exact synthetic edit needed to replace one verified trailing typo.
///
/// Keeping this as a value type lets the coordinator validate first and perform side effects second.
/// That separation matters for Accessibility-backed editors, where the field may change between the
/// original correction offer and the eventual edit.
struct TypoCorrectionReplacement: Equatable, Sendable {
    let deletingUTF16Count: Int
    let replacementText: String
}

/// Builds a fail-closed replacement from the latest text before the caret.
///
/// Both accepted green corrections and automatic post-Space fixes use this planner. Centralizing the
/// word-match and delimiter-preservation rules prevents the two paths from drifting and accidentally
/// deleting a different word after the user continues typing.
enum TypoCorrectionReplacementPlanner {
    static func plan(
        precedingText: String,
        expectedTypo: String,
        correctedWord: String,
        requiresTrailingSpace: Bool
    ) -> TypoCorrectionReplacement? {
        let normalizedCorrection = correctedWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCorrection.isEmpty,
              normalizedCorrection != expectedTypo,
              let live = CaretWordContext.committedWord(in: precedingText),
              live.word == expectedTypo,
              !requiresTrailingSpace || live.delimiter == " " else {
            return nil
        }

        return TypoCorrectionReplacement(
            deletingUTF16Count: ((expectedTypo + live.delimiter) as NSString).length,
            replacementText: normalizedCorrection + live.delimiter
        )
    }
}
