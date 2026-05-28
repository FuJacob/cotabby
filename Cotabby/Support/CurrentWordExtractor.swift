import Foundation

/// File overview:
/// Pure helper that pulls the trailing word out of the text before the caret. Used by the typo
/// gate before we decide whether to suppress a completion or flip into correction mode.
///
/// We intentionally do not lean on `NSLinguisticTagger` or `NLTokenizer` here — both pull in
/// language detection that's overkill for the "is the cursor inside or just after a word"
/// question. A whitespace walk is faster, deterministic, and easy to reason about.
enum CurrentWordExtractor {
    struct Result: Equatable, Sendable {
        let word: String
        /// Number of extended grapheme clusters in the word — what the inserter uses to know how
        /// many backspace events to synthesize when replacing the typo with a correction.
        let characterCount: Int
    }

    /// Returns the trailing word at the cursor, or `nil` when:
    ///  - the cursor is on (or just after) whitespace,
    ///  - the trailing token is implausible as natural language (URL, code, all-caps acronym,
    ///    digits), so `NSSpellChecker` would over-flag it,
    ///  - the trailing token is too short (single-letter words are too noisy to act on).
    static func extract(from precedingText: String) -> Result? {
        guard let lastCharacter = precedingText.last, !lastCharacter.isWhitespace else {
            return nil
        }

        // Walk back to the previous whitespace boundary; that's the start of the trailing word.
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
        return Result(word: word, characterCount: word.count)
    }

    /// Filter out tokens that aren't natural-language words so we don't slap a "typo" flag onto
    /// the user's variable names, URLs, mentions, or numeric values. Keep this conservative —
    /// false negatives (we miss a real typo) are fine; false positives (we flag code as a typo)
    /// would be very annoying.
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

        // All-uppercase tokens are almost always acronyms (USA, HTTP, JSON). NSSpellChecker
        // flags many of them as typos but that's not useful here.
        let letters = word.filter { $0.isLetter }
        if !letters.isEmpty, letters.allSatisfy({ $0.isUppercase }) {
            return false
        }

        return true
    }
}
