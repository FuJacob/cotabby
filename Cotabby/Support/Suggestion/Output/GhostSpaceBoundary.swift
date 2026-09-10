import Foundation

/// File overview:
/// The single rule for whether ghost text carries a leading space, evaluated against the text that
/// is in the field RIGHT NOW.
///
/// Why this exists: the normalizer decides the leading space while building the request, from the
/// preceding text as it was when generation started. The user keeps typing during those tens to
/// hundreds of milliseconds, so by the time the ghost appears the decision can be stale in both
/// directions, and every one of the space complaints follows from that:
///   - the space arrives during generation: the field now ends with a space and the ghost still
///     carries one, so the ghost sits a space too far right and accepting yields two spaces;
///   - the model returned no leading space after a word: accepting glues the words together;
///   - a backspace removes the space after the request was built: the ghost has none and accepting
///     glues.
///
/// The rule is a pure function of three things, so it can be applied wherever the live text is
/// known (when a result becomes a session, and again when the session reconciles against a fresh
/// snapshot) and always agrees with itself:
///   1. a completion that continues the user's half-typed word never takes a space (the request was
///      anchored at the word boundary and the completion is the rest of that word);
///   2. a completion opening with closing punctuation never takes a space (", regards" after
///      "Best" is a comma attaching to the word, not a new one);
///   3. otherwise there is exactly one space between a word character and the completion's first
///      word character, and never a space after whitespace or an opening bracket.
///
/// `Support/` and pure on purpose: the same rule has to hold at generation time, at presentation
/// time and at acceptance time, and it is far easier to trust one tested function than three
/// consistent-looking branches.
nonisolated enum GhostSpaceBoundary {
    /// Punctuation that binds to the preceding word, so a space before it would be wrong.
    private static let bindingPunctuation: Set<Character> = [
        ",", ".", ";", ":", "!", "?", "…", ")", "]", "}", "'", "\u{2019}", "\"", "%", "/", "-", "\u{2014}"
    ]
    /// Characters after which a following space would be wrong even though they are not whitespace.
    private static let openingCharacters: Set<Character> = ["(", "[", "{", "\u{201C}", "\u{2018}", "/", "-", "@", "#", "$"]

    /// The completion with exactly the right number of leading spaces for `precedingText`.
    ///
    /// `continuesPartialWord` must be true when the request was anchored at a word boundary (see
    /// `WordBoundaryAnchorPolicy`): the completion then finishes the word under the caret and any
    /// leading whitespace in it is model noise.
    static func adjusted(
        _ completion: String,
        precedingText: String,
        continuesPartialWord: Bool
    ) -> String {
        guard !completion.isEmpty else { return completion }
        let stripped = String(completion.drop(while: { $0 == " " || $0 == "\u{00A0}" }))
        guard !stripped.isEmpty else { return completion }
        return needsLeadingSpace(
            stripped, precedingText: precedingText, continuesPartialWord: continuesPartialWord
        ) ? " " + stripped : stripped
    }

    /// Whether one space belongs between `precedingText` and a completion that has none.
    static func needsLeadingSpace(
        _ completion: String,
        precedingText: String,
        continuesPartialWord: Bool
    ) -> Bool {
        guard !continuesPartialWord else { return false }
        guard let first = completion.first, let last = precedingText.last else { return false }
        // After whitespace or a line break the user (or the host) already supplied the boundary.
        guard !last.isWhitespace else { return false }
        guard !openingCharacters.contains(last) else { return false }
        guard !bindingPunctuation.contains(first) else { return false }
        // A colon between digits is a ratio or a time ("1:1", "10:30"), not a clause boundary.
        if last == ":", first.isNumber, precedingText.dropLast().last?.isNumber == true {
            return false
        }
        // A straight double quote closes a quotation only when it is the second of a pair; an
        // unpaired one is opening, and the quoted text follows it directly.
        if last == "\"", precedingText.filter({ $0 == "\"" }).count % 2 == 1 {
            return false
        }
        // Only a real word start earns a space; a completion opening with anything else is either
        // punctuation handled above or a shape whose spacing the model owns.
        return (last.isLetter || last.isNumber || bindingPunctuation.contains(last))
            && (first.isLetter || first.isNumber)
    }
}
