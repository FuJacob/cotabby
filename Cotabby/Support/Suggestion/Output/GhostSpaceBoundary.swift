import Foundation

/// File overview:
/// The single rule for whether ghost text carries a leading space, evaluated against the text that
/// is in the field RIGHT NOW.
///
/// Why this exists: the normalizer decides the leading space while building the request, from the
/// preceding text as it was when generation started. The user keeps typing during those tens to
/// hundreds of milliseconds, so by the time the ghost appears the decision can be stale in both
/// directions:
///   - the space arrives during generation: the field now ends with a space and the ghost still
///     carries one, so the ghost sits a space too far right and accepting yields two spaces;
///   - a backspace removes the space after the request was built: the ghost has none and accepting
///     glues.
///
/// Whose word boundary it is. A base completion model writes the space itself: its completion is
/// text that follows the request's preceding text exactly, so a completion that starts without a
/// space after a word or a digit continues that word ("1" + "50K" is 150K, "It'" + "s" is It's),
/// and one that starts with a space starts a new word. Measured 2026-09-10 in Claude's composer: a
/// rule that put a space between any two word characters showed "1 50K", "10 0%" and "It' s" over
/// ghosts the model had written joined (66 presentations in fifteen minutes). So when the engine
/// vouches for its spacing (`requestPrecedingText` is given), the completion's own leading space
/// decides, and the live text only removes a space the field already has or restores one the field
/// lost since the request was built. Engines that do not vouch for it (instruct and chat models
/// drop leading spaces) get the word-character rule, with digits and in-word apostrophes joined.
///
/// A word-boundary-anchored request (the user's half-typed word re-anchored at its start, see
/// `WordBoundaryAnchorPolicy`) is decided the same way: what remains after the anchor starts with a
/// space only when the model ended the word there. Measured in the same session: 52 times the user
/// had typed a whole word ("that", "PM"), the model returned " that the timeline…", and a rule that
/// treated every anchored remainder as the rest of the word stripped the space, gluing
/// "thatthe timeline" until the user typed the space and the ghost vanished.
///
/// The rule is a pure function of its inputs, so it can be applied wherever the live text is known
/// (when a result becomes a session, a streamed partial, a prefetched continuation) and always
/// agrees with itself:
///   1. a completion that continues the word before the caret never takes a space;
///   2. a completion opening with closing punctuation never takes a space (", regards" after
///      "Best" is a comma attaching to the word, not a new one);
///   3. otherwise there is exactly one space before a new word, and never a space after whitespace
///      or an opening bracket.
///
/// `Support/` and pure on purpose: the same rule has to hold at generation time, at presentation
/// time and at acceptance time, and it is far easier to trust one tested function than three
/// consistent-looking branches.
nonisolated enum GhostSpaceBoundary {
    /// What the model's own spacing says about the completion's first word.
    enum ModelBoundary: Equatable, Sendable {
        /// The completion continues the word (or number) before the caret: never a space.
        case sameWord
        /// The completion starts a new word: one space, unless the field already supplies one.
        case newWord
        /// The engine does not vouch for its spacing: decide from the characters on either side.
        case unknown
    }

    /// Punctuation that binds to the preceding word, so a space before it would be wrong.
    private static let bindingPunctuation: Set<Character> = [
        ",", ".", ";", ":", "!", "?", "…", ")", "]", "}", "'", "\u{2019}", "\"", "%", "/", "-", "\u{2014}"
    ]
    /// Characters after which a following space would be wrong even though they are not whitespace.
    private static let openingCharacters: Set<Character> = ["(", "[", "{", "\u{201C}", "\u{2018}", "/", "-", "@", "#", "$"]

    /// The completion with exactly the right number of leading spaces for `precedingText`.
    ///
    /// - Parameters:
    ///   - precedingText: the field's text before the caret now.
    ///   - requestPrecedingText: the text before the caret the request was built from, given only
    ///     when the engine's completion is exact text following it (a base model, whose leading
    ///     space is its own word boundary). Nil for engines whose spacing cannot be trusted.
    ///   - continuesPartialWord: true when the request was anchored at a word boundary; the
    ///     completion is then what remains after the user's half-typed word.
    static func adjusted(
        _ completion: String,
        precedingText: String,
        requestPrecedingText: String? = nil,
        continuesPartialWord: Bool
    ) -> String {
        guard !completion.isEmpty else { return completion }
        let stripped = String(completion.drop(while: isSpace))
        guard !stripped.isEmpty else { return completion }
        let boundary = modelBoundary(
            leadsWithSpace: completion.first.map(isSpace) ?? false,
            requestPrecedingText: requestPrecedingText,
            continuesPartialWord: continuesPartialWord
        )
        return needsLeadingSpace(stripped, precedingText: precedingText, boundary: boundary) ? " " + stripped : stripped
    }

    /// Punctuation that can only attach to the word before it.
    private static let attachingPunctuation: Set<Character> = [",", ".", ";", ":", "!", "?", "…", ")", "]", "}", "%"]

    /// True when the completion opens with punctuation that attaches to the word before the caret
    /// while the field now ends with whitespace: the user ended that word after the request was
    /// built, so the completion is stale. Measured 2026-09-10 in Chrome's contenteditable:
    /// ". I'm going to bed now." written for "Friday" arrived after the space and read
    /// "Friday . I'm".
    static func isStaleAfterTypedSpace(_ completion: String, precedingText: String) -> Bool {
        guard let last = precedingText.last, last.isWhitespace,
              let first = completion.first(where: { !isSpace($0) })
        else {
            return false
        }
        return attachingPunctuation.contains(first)
    }

    /// Reads the model's own boundary decision from the completion's leading space.
    static func modelBoundary(
        leadsWithSpace: Bool,
        requestPrecedingText: String?,
        continuesPartialWord: Bool
    ) -> ModelBoundary {
        if continuesPartialWord {
            // The remainder after the anchor starts with a space only when the model ended the
            // user's word there; otherwise it is the rest of that word.
            return leadsWithSpace ? .newWord : .sameWord
        }
        guard let requestPrecedingText else { return .unknown }
        // After a request text that ended with whitespace, the normalizer removed the model's
        // leading space (the field's own space was the boundary): the completion is a new word.
        if requestPrecedingText.last.map({ $0.isWhitespace }) ?? true {
            return .newWord
        }
        return leadsWithSpace ? .newWord : .sameWord
    }

    /// Whether one space belongs between `precedingText` and a completion that has none.
    static func needsLeadingSpace(
        _ completion: String,
        precedingText: String,
        boundary: ModelBoundary
    ) -> Bool {
        guard boundary != .sameWord else { return false }
        guard let first = completion.first, let last = precedingText.last else { return false }
        // After whitespace or a line break the user (or the host) already supplied the boundary, and
        // a completion opening with a line break needs none.
        guard !last.isWhitespace, !first.isWhitespace else { return false }
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
        if boundary == .newWord {
            return true
        }
        // Unknown boundary: word characters on both sides take a space, except the shapes that are
        // one word whatever the engine meant: a number continued by digits ("1" + "50K") and a
        // contraction after an in-word apostrophe ("It'" + "s").
        if last.isNumber, first.isNumber {
            return false
        }
        if isInWordApostrophe(precedingText), first.isLetter {
            return false
        }
        // Only a real word start earns a space; a completion opening with anything else is either
        // punctuation handled above or a shape whose spacing the model owns.
        return (last.isLetter || last.isNumber || bindingPunctuation.contains(last))
            && (first.isLetter || first.isNumber)
    }

    private static func isSpace(_ character: Character) -> Bool {
        character == " " || character == "\u{00A0}"
    }

    /// An apostrophe right after a letter ("It'", "don’"): the word goes on after it. Not when the
    /// word opened with a quote ("'hello'"): that apostrophe closes the quotation.
    private static func isInWordApostrophe(_ text: String) -> Bool {
        guard let last = text.last, last == "'" || last == "\u{2019}" else { return false }
        guard text.dropLast().last?.isLetter == true else { return false }
        let word = text.reversed().prefix(while: { !$0.isWhitespace })
        guard let opening = word.last else { return false }
        return opening != "'" && opening != "\u{2018}" && opening != "\""
    }
}
