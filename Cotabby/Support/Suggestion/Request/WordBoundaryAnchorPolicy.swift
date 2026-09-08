import Foundation

/// File overview:
/// Re-anchors a mid-word request at the start of the word the user is typing.
///
/// A base model asked to continue "…I really apprec" completes the *tokens* it sees, and the
/// tokenizer split that word at an arbitrary byte: the eval collected "rd to this", "ate it!",
/// "etly try it out", "atly, I don't…" — thirteen of fourteen mid-word cases ended as misspellings
/// the seam guard then suppressed, so Cotabby showed nothing while a word was being typed, which is
/// most of the time. Prompting from the word boundary instead ("…I really") lets the model produce
/// a whole, correctly spelled word (" appreciate"); the normalizer then requires that word to start
/// with what the user already typed and shows only the remainder ("iate"). A mismatch shows nothing.
enum WordBoundaryAnchorPolicy {
    static let minimumAnchorLength = 2
    static let maximumAnchorLength = 24

    /// The partial word the caret sits at the end of, when re-anchoring applies: letters only, at
    /// least two of them, preceded by whitespace or the start of text, with nothing word-like right
    /// after the caret. Nil at word boundaries, after digits or punctuation, and inside tokens.
    static func anchor(precedingText: String, trailingText: String) -> String? {
        guard !CaretTokenPosition.isInsideToken(precedingText: precedingText, trailingText: trailingText) else {
            return nil
        }
        var letters: [Character] = []
        var index = precedingText.endIndex
        while index > precedingText.startIndex {
            let previous = precedingText.index(before: index)
            let character = precedingText[previous]
            if character.isLetter {
                letters.append(character)
                index = previous
                continue
            }
            // Only a plain word counts: "don'|t", "e-|mail" and "user1|" stay with the model as is.
            guard character.isWhitespace else { return nil }
            break
        }
        guard letters.count >= minimumAnchorLength, letters.count <= maximumAnchorLength else { return nil }
        return String(letters.reversed())
    }

    /// The prefix with the anchor removed, ending at the word boundary the anchor started at.
    static func promptPrefix(_ prefixText: String, removing anchor: String) -> String {
        guard prefixText.hasSuffix(anchor) else { return prefixText }
        return String(prefixText.dropLast(anchor.count))
    }

    /// Reconciles a completion generated from the word boundary with the user's partial word: the
    /// completion must start (case-insensitively, after any leading whitespace) with the anchor, and
    /// what remains is the ghost text. Nil when the model went for a different word.
    static func remainder(of completion: String, anchor: String) -> String? {
        let trimmed = completion.drop(while: { $0.isWhitespace })
        guard trimmed.count >= anchor.count else { return nil }
        let head = String(trimmed.prefix(anchor.count))
        guard head.compare(anchor, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame else {
            return nil
        }
        return String(trimmed.dropFirst(anchor.count))
    }
}
