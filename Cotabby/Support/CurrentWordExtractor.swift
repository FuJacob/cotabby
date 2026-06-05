import Foundation

/// File overview:
/// Pure helper that pulls the trailing word out of the text before the caret. Used by the typo
/// gate to decide whether to suppress a completion or offer a correction, and again at accept time
/// to recompute how many characters to delete from the *live* field.
///
/// We intentionally do not lean on `NSLinguisticTagger` or `NLTokenizer` here. Both pull in language
/// detection that is overkill for the "is the cursor inside or just after a word" question. A
/// whitespace walk is faster, deterministic, and easy to reason about.
enum CurrentWordExtractor {
    struct Result: Equatable, Sendable {
        let word: String
        /// Number of extended grapheme clusters in the word. This is the count the inserter needs:
        /// one Delete keypress removes one user-perceived character, so deleting the word back to its
        /// start takes exactly this many backspaces.
        let characterCount: Int
    }

    /// Returns the trailing word at the cursor, or `nil` when:
    ///  - the cursor is on (or just after) whitespace (so there is no "current word"),
    ///  - the trailing token is implausible as natural language (URL, code, all-caps acronym,
    ///    digits), where `NSSpellChecker` would over-flag,
    ///  - the trailing token is too short (single-letter words are too noisy to act on).
    static func extract(from precedingText: String) -> Result? {
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
        return Result(word: word, characterCount: word.count)
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
