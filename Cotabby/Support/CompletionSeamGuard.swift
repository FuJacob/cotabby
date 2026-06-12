import Foundation

/// Post-generation guard for the two classic visible failures at the caret seam: junk punctuation
/// runs ("....", "$$$$") and mid-word splices that turn the word being typed into a misspelling
/// ("gre" + "atful"). Showing nothing beats showing either, and both checks are pure string work
/// on a single short completion, so the guard costs microseconds once per generation.
///
/// Both rules are deliberately narrow so they fire rarely:
///
/// - **Junk run**: a run of four or more identical punctuation/symbol characters inside the
///   completion, unless the run merely extends an identical run the user already has at the caret
///   (continuing an existing `----` divider is legitimate).
/// - **Seam misspelling**: only in the mid-word case (caret inside a word, completion starts with
///   word characters), the joined word formed across the seam must be known to the spell checker.
///   Skipped for capitalized words (names and brands are routinely out-of-dictionary), for short
///   joins (under four letters), for words with digits, and for CJK text (no space-delimited word
///   boundaries, and the dictionaries do not cover it).
nonisolated enum CompletionSeamGuard {
    enum Verdict: Equatable {
        case allow
        case junkPunctuationRun
        case seamMisspelling(word: String)
    }

    /// Identical punctuation/symbol characters in a row that count as junk when freshly introduced.
    private static let junkRunLength = 4

    /// Joined seam words shorter than this are too ambiguous to judge ("a" + "t").
    private static let minimumSeamWordLength = 4

    /// Streaming-path variant: only the pure junk-run rule. Partials drain at token cadence, so
    /// the spell-lookup half of the guard (an XPC round trip) stays off that path; the full
    /// verdict still gates the final result, which authoritatively replaces whatever streamed.
    static func allowsStreamedPartial(precedingText: String, completion: String) -> Bool {
        !introducesJunkPunctuationRun(precedingText: precedingText, completion: completion)
    }

    /// `isKnownWord` is injected so the pure rule stays testable and the caller picks the spell
    /// checking backend; it is only invoked when the mid-word rule actually applies.
    static func verdict(
        precedingText: String,
        completion: String,
        isKnownWord: (String) -> Bool
    ) -> Verdict {
        if introducesJunkPunctuationRun(precedingText: precedingText, completion: completion) {
            return .junkPunctuationRun
        }

        if let seamWord = misspellingCandidateSeamWord(
            precedingText: precedingText,
            completion: completion
        ), !isKnownWord(seamWord) {
            return .seamMisspelling(word: seamWord)
        }

        return .allow
    }

    // MARK: - Junk punctuation runs

    private static func introducesJunkPunctuationRun(
        precedingText: String,
        completion: String
    ) -> Bool {
        var runCharacter: Character?
        var runLength = 0
        var runStartsAtCompletionStart = false
        var index = 0

        for character in completion {
            if character == runCharacter {
                runLength += 1
            } else {
                runCharacter = character
                runLength = 1
                runStartsAtCompletionStart = index == 0
            }
            index += 1

            guard runLength >= junkRunLength,
                  let current = runCharacter,
                  current.isPunctuation || current.isSymbol
            else { continue }

            // A run flush against the seam that continues a run of the same character the user
            // already has at the caret is an existing divider being extended, not fresh junk.
            // It must be a real preceding run (two or more): a sentence that merely ends in "."
            // must not exempt "...." from the completion.
            if runStartsAtCompletionStart, trailingRunLength(of: precedingText, character: current) >= 2 {
                continue
            }
            return true
        }
        return false
    }

    // MARK: - Seam misspellings

    /// The joined word across the caret seam when the mid-word rule applies, or nil when any of
    /// the narrowing conditions exempt it.
    private static func misspellingCandidateSeamWord(
        precedingText: String,
        completion: String
    ) -> String? {
        guard let lastBefore = precedingText.last, lastBefore.isLetter,
              let firstAfter = completion.first, firstAfter.isLetter
        else { return nil }

        let head = trailingLetterRun(of: precedingText)
        let tail = leadingLetterRun(of: completion)
        let seamWord = head + tail

        guard seamWord.count >= minimumSeamWordLength else { return nil }
        // Capitalized joins are usually names or brands the dictionary cannot know.
        guard let firstCharacter = seamWord.first, firstCharacter.isLowercase else { return nil }
        guard !containsCJK(seamWord) else { return nil }
        return seamWord
    }

    private static func trailingRunLength(of text: String, character: Character) -> Int {
        text.reversed().prefix(while: { $0 == character }).count
    }

    private static func trailingLetterRun(of text: String) -> String {
        String(text.reversed().prefix(while: { $0.isLetter }).reversed())
    }

    private static func leadingLetterRun(of text: String) -> String {
        String(text.prefix(while: { $0.isLetter }))
    }

    /// Han, kana, and Hangul ranges; CJK has no space-delimited words, so a "seam word" is not a
    /// meaningful unit there and the spelling dictionaries do not cover these scripts. The
    /// 0x2E80-0x9FFF block already spans the kana ranges, so they are not listed separately.
    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF65...0xFF9F:
                return true
            default:
                return false
            }
        }
    }
}
