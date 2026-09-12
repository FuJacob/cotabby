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
/// with what the user already typed and shows only the remainder ("iate").
///
/// The model's free choice of next word matches the user's letters only rarely (measured live at
/// 90ms a key in a Chrome textarea with the shipped model: 8 of 67 anchored requests), so the
/// anchor is not left to chance: the llama engine is handed the boundary whitespace plus the typed
/// letters as a required prefix (`requiredCompletionPrefix`) and masks every token inconsistent with
/// them until they are produced. The model then finishes the word the user started, with the
/// prompt still ending in whole tokens. Every partial word is anchored this way; the plain
/// continuation of a word cut at an arbitrary byte was junk most of the time ("yest" → "arday",
/// "sen" → "-ding", "dra" → "fter", "th" → "x! Jacob.").
enum WordBoundaryAnchorPolicy {
    static let minimumAnchorLength = 1
    static let maximumAnchorLength = 24

    /// The bytes an anchored completion must begin with: the space that separated the anchor from
    /// the word before it, then the anchor itself. The prompt has that space trimmed away (a
    /// tokenizer carries a word's space on the word), so the completion must supply it. A line
    /// break stays at the end of the prompt instead (see
    /// `BaseCompletionPromptRenderer.trimmingTrailingWhitespace`) and the completion begins with the
    /// anchor: required as a prefix, the break let the model open with a token whose text is empty,
    /// after which no completion matched the typed letters and nothing was shown (a Chrome page
    /// modelled on Claude's composer, 2026-09-11: "<unused9>" first on every request for a new line's first
    /// word, all dropped as word-boundary mismatches).
    static func requiredCompletionPrefix(precedingText: String, anchor: String) -> String {
        guard precedingText.hasSuffix(anchor) else { return anchor }
        let beforeAnchor = precedingText.dropLast(anchor.count)
        guard let separator = beforeAnchor.last, separator.isWhitespace, !separator.isNewline else { return anchor }
        return String(separator) + anchor
    }

    /// The partial word the caret sits at the end of, when re-anchoring applies: letters only,
    /// preceded by whitespace or the start of text, with nothing word-like right after the caret.
    /// Nil at word boundaries, after digits or punctuation, and inside tokens.
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
