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

    /// Like `extract(from:)`, but tolerates exactly one trailing space so a *just-finished* word
    /// (the user typed the word and then pressed space) is still surfaced as the trailing word.
    /// Returns the word plus how many trailing spaces were skipped (0 or 1).
    ///
    /// This is what lets an offered correction survive the user pressing space: the word is still
    /// recognized, the green fix stays acceptable, and the accept path knows to preserve the space.
    /// Two or more trailing spaces (the user has moved on), a non-space trailing whitespace, or no
    /// plausible word before the space all return nil. Only a single literal space is tolerated.
    static func extractTrailingWord(from precedingText: String) -> (result: Result, trailingSpaceCount: Int)? {
        guard precedingText.last == " " else {
            // No trailing space: fall back to the strict current-word extraction.
            return extract(from: precedingText).map { ($0, 0) }
        }

        let withoutSpace = String(precedingText.dropLast())
        // A second trailing whitespace means the caret is no longer adjacent to a finished word.
        if withoutSpace.last?.isWhitespace == true {
            return nil
        }
        guard let result = extract(from: withoutSpace) else {
            return nil
        }
        return (result, 1)
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
/// word-match and whitespace-preservation rules prevents the two paths from drifting and accidentally
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
              let live = CurrentWordExtractor.extractTrailingWord(from: precedingText),
              live.result.word == expectedTypo,
              !requiresTrailingSpace || live.trailingSpaceCount == 1 else {
            return nil
        }

        let preservedSpaces = String(repeating: " ", count: live.trailingSpaceCount)
        return TypoCorrectionReplacement(
            deletingUTF16Count: (expectedTypo as NSString).length + live.trailingSpaceCount,
            replacementText: normalizedCorrection + preservedSpaces
        )
    }
}
