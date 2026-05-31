import Foundation

/// File overview:
/// Decides whether a period actually ends a sentence, so phrase-level acceptance does not stop
/// early on decimals, list numbers, single-letter initials, or common abbreviations.
///
/// Why this file exists:
/// Phrase acceptance treats any `.` as a sentence terminator. That breaks "version 1.2", "U.S.",
/// "e.g.", and a numbered "1." mid-tail. A purely structural scanner cannot resolve every case, but
/// it can resolve the frequent ones with a few local rules. `!` and `?` are always terminal and do
/// not need this; only the period is ambiguous.
enum SentenceBoundaryClassifier {
    /// Lowercased abbreviations whose trailing period is part of the word, not a sentence end.
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "st", "vs", "eg", "ie", "etc", "no", "fig", "approx", "inc", "ltd"
    ]

    /// Whether the period at `periodIndex` in `text` ends a sentence. The caller guarantees that
    /// `text[periodIndex]` is ".".
    static func isTerminalPeriod(in text: String, at periodIndex: String.Index) -> Bool {
        guard periodIndex > text.startIndex else {
            // A leading period has no preceding word to qualify it; treat it as terminal so behavior
            // matches the previous unconditional rule for this edge.
            return true
        }

        let beforeIndex = text.index(before: periodIndex)
        let beforeChar = text[beforeIndex]

        // Decimals, version numbers, and list/ordinal markers ("1.", "3.14") are not sentence ends.
        if beforeChar.isNumber {
            return false
        }

        if beforeChar.isLetter {
            // Single-letter initial ("U.", the "S." in "U.S."): the letter stands alone, with a
            // non-letter (or nothing) before it.
            let priorIsLetter = beforeIndex > text.startIndex && text[text.index(before: beforeIndex)].isLetter
            if !priorIsLetter {
                return false
            }
            // Known abbreviation ending in a period.
            if abbreviations.contains(trailingLetters(in: text, endingBefore: periodIndex).lowercased()) {
                return false
            }
        }

        return true
    }

    /// The run of letters in `text` ending just before `index`.
    private static func trailingLetters(in text: String, endingBefore index: String.Index) -> String {
        var letters: [Character] = []
        var cursor = index
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            guard text[previous].isLetter else {
                break
            }
            letters.append(text[previous])
            cursor = previous
        }
        return String(letters.reversed())
    }
}
