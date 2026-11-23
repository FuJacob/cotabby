import Foundation

/// File overview:
/// Rejects completions that are technically non-empty but would insert nothing a user wants, or
/// would insert something other than what the ghost text showed.
///
/// Why this file exists:
/// `SuggestionInserter` previously only refused a fully empty string, so a completion carrying an
/// interior control character or a U+FFFD replacement glyph (from lossy detokenization) could reach
/// ghost text and be committed on Tab. This gate is the single predicate for "is this safe to put
/// on screen and insert."
///
/// The ghost is the user's only preview of what Tab will type, so a scalar that draws nothing, or
/// that reorders the text around it, breaks that preview: the field receives text the user never
/// saw. Model output, endpoint responses, and screen text that steers a model are all untrusted, so
/// such scalars are refused here rather than trusted to be harmless. The list is deliberately
/// narrower than "every format character" (Unicode category Cf): several Cf scalars are required
/// to spell real text correctly, and refusing them would silently disable suggestions for whole
/// languages. See `isRejected(_:)` for what is refused and what is kept, and why.
///
/// Scope note: this intentionally does NOT reject punctuation-only output. A lone ")", ".", or "?"
/// is a legitimate inline completion (closing a bracket, ending a sentence), so judging punctuation
/// here would suppress useful suggestions. The gate is limited to unambiguous junk.
enum InsertionSafetyGate {
    /// A subdivision code inside an emoji tag sequence is a two-letter or three-digit region plus a
    /// one-to-four character suffix (UTS #51 `unicode_subdivision_id`), so 3 to 7 tag characters.
    private static let subdivisionTagLengths = 3...7

    /// Returns true when `completion` is safe to display and insert.
    static func isSafeToInsert(_ completion: String) -> Bool {
        guard !completion.isEmpty else {
            return false
        }

        let scalars = Array(completion.unicodeScalars)
        var sawVisibleContent = false
        var index = 0
        while index < scalars.count {
            // A subdivision flag (England, Scotland, Wales) is the one place tag characters are
            // legitimate text. Step over the whole sequence as one visible glyph, so the tag rule in
            // `isRejected` only ever sees tags outside a flag, where they carry hidden ASCII.
            if let sequenceEnd = emojiTagSequenceEnd(in: scalars, from: index) {
                sawVisibleContent = true
                index = sequenceEnd
                continue
            }
            let scalar = scalars[index]
            if isRejected(scalar) {
                return false
            }
            if !CharacterSet.whitespacesAndNewlines.contains(scalar), !isPermittedInvisible(scalar) {
                sawVisibleContent = true
            }
            index += 1
        }

        // Whitespace-only output is not a completion, and neither is output made only of the
        // invisible joiners and marks that are allowed between visible characters.
        return sawVisibleContent
    }

    /// Scalars that are never content in an inline completion.
    ///
    /// Kept on purpose, because real text needs them: U+200C ZERO WIDTH NON-JOINER (Persian, Urdu,
    /// and Indic spelling), U+200D ZERO WIDTH JOINER (emoji sequences and Indic conjuncts), U+200E and
    /// U+200F (LRM/RLM, which RTL text uses to place punctuation and digits), the Arabic letter mark
    /// U+061C, and the variation selectors U+FE00–U+FE0F and U+E0100–U+E01EF (emoji vs. text
    /// presentation, ideographic variants). The bidi marks are kept because, unlike the embeddings,
    /// overrides, and isolates refused below, a mark affects only the neutral characters next to it
    /// and cannot reverse a run of letters.
    private static func isRejected(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A:
            // A line feed is legitimate content in a multi-line completion (the normalizer keeps
            // newlines when multi-line mode is on), so it must pass.
            return false
        case 0x00...0x1F, 0x7F...0x9F:
            // C0 controls, DEL, and C1 controls: an interior tab, a stray escape, or a C1 control
            // decoded from bad bytes is corruption, not content.
            return true
        case 0xAD:
            // SOFT HYPHEN draws nothing unless the host breaks a line at it, so mid-line it is an
            // invisible scalar inside a word. An inline continuation never needs a hyphenation hint,
            // and the only effect of letting one through is a typed word that no longer matches what
            // search, spell check, or a later paste expects.
            return true
        case 0x202A...0x202E, 0x2066...0x2069:
            // Bidi embeddings, overrides, and isolates reorder the text that follows them, so the
            // characters that land in the field can be in a different order than they appeared.
            return true
        case 0x2028, 0x2029:
            // LINE and PARAGRAPH SEPARATOR break lines in some hosts and draw nothing in others,
            // including the single-line ghost. Multi-line completions use a line feed instead.
            return true
        case 0x180E, 0x200B, 0xFEFF, 0x2060...0x2065, 0x206A...0x206F:
            // Zero-width and invisible characters: MONGOLIAN VOWEL SEPARATOR, ZERO WIDTH SPACE, the
            // byte-order mark, WORD JOINER, the invisible math operators, and the deprecated format
            // controls. Each draws nothing, so it can split or pad a word without the ghost showing it.
            return true
        case 0xE0000...0xE007F:
            // Tag characters outside a valid flag sequence (handled by the caller) mirror ASCII
            // invisibly, which is a known way to smuggle hidden text through a visible string.
            return true
        case 0xFFFD:
            // Replacement character: the detokenizer produced bytes it could not decode. Never text.
            return true
        default:
            return false
        }
    }

    /// Allowed scalars that draw nothing on their own. They are fine between visible characters but
    /// do not by themselves make a completion worth showing.
    private static func isPermittedInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x061C, 0x200C...0x200F, 0xFE00...0xFE0F, 0xE0100...0xE01EF:
            return true
        default:
            return false
        }
    }

    /// When `start` begins an emoji subdivision flag (U+1F3F4, then a lowercase-letter-or-digit tag
    /// run, then U+E007F CANCEL TAG), returns the index just past it; otherwise nil. U+1F3F4 is the
    /// only tag base Unicode recommends, so tags after any other base are treated as hidden text.
    private static func emojiTagSequenceEnd(in scalars: [Unicode.Scalar], from start: Int) -> Int? {
        guard scalars[start].value == 0x1F3F4 else {
            return nil
        }
        var index = start + 1
        while index < scalars.count, isSubdivisionTag(scalars[index]) {
            index += 1
        }
        let tagCount = index - start - 1
        guard subdivisionTagLengths.contains(tagCount),
              index < scalars.count,
              scalars[index].value == 0xE007F else {
            return nil
        }
        return index + 1
    }

    /// TAG DIGIT ZERO–NINE and TAG LATIN SMALL LETTER A–Z: the only tags a subdivision code uses.
    private static func isSubdivisionTag(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0xE0030...0xE0039, 0xE0061...0xE007A:
            return true
        default:
            return false
        }
    }
}
