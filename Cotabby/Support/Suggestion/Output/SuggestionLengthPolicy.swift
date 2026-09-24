import Foundation

/// File overview:
/// Keeps every suggestion inside the user's word-count preset so consecutive ghosts read as the same
/// kind of thing: a phrase of a handful of words, not one word now and a full sentence next.
///
/// Length varied for two reasons. Decoding stopped at the first sentence end even one word in
/// ("report."), and otherwise ran to the token budget, which at the preset's upper bound could
/// spill a word or two past it. The decode side now waits for the preset's minimum before a
/// sentence end may stop it (see `DecodeStopPolicy`); this policy handles the top: text past the
/// maximum is cut at a word boundary, and when a clause boundary exists inside the window the cut
/// prefers it so the ghost ends where a reader would pause.
enum SuggestionLengthPolicy {
    /// Punctuation after which a suggestion may end early inside the window.
    private static let clauseBoundaries: Set<Character> = [",", ";", ":", ".", "!", "?", "\u{2014}", "\u{2013}"]

    /// Returns `text` trimmed to at most `maximum` words (leading whitespace preserved). When at least
    /// `minimum` words fit before a clause boundary that lies inside the window, the text ends there.
    static func trimmed(_ text: String, minimum: Int, maximum: Int) -> String {
        guard maximum > 0 else { return text }
        let words = wordRanges(in: text)
        guard words.count > maximum else {
            return text
        }
        // Prefer a clause boundary between the minimum and the maximum word, latest first.
        for index in stride(from: maximum - 1, through: max(minimum, 1) - 1, by: -1) where index < words.count {
            let end = words[index].upperBound
            if let last = text[words[index]].last, clauseBoundaries.contains(last) {
                return String(text[..<end])
            }
        }
        return String(text[..<words[maximum - 1].upperBound])
    }

    /// Ranges of the whitespace-separated words in `text`, in order.
    private static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                if let wordStart = start {
                    ranges.append(wordStart..<index)
                    start = nil
                }
            } else if start == nil {
                start = index
            }
            index = text.index(after: index)
        }
        if let wordStart = start {
            ranges.append(wordStart..<text.endIndex)
        }
        return ranges
    }
}
