import Foundation

/// File overview:
/// Rejects completions that are technically non-empty but would insert nothing a user wants.
///
/// Why this file exists:
/// `SuggestionInserter` previously only refused a fully empty string, so a completion carrying an
/// interior control character or a U+FFFD replacement glyph (from lossy detokenization) could reach
/// ghost text and be committed on Tab. This gate is the single predicate for "is this safe to put
/// on screen and insert."
///
/// Scope note: this intentionally does NOT reject punctuation-only output. A lone ")", ".", or "?"
/// is a legitimate inline completion (closing a bracket, ending a sentence), so judging punctuation
/// here would suppress useful suggestions. The gate is limited to unambiguous junk.
enum InsertionSafetyGate {
    /// Returns true when `completion` is safe to display and insert.
    static func isSafeToInsert(_ completion: String) -> Bool {
        guard !completion.isEmpty else {
            return false
        }

        var sawNonWhitespace = false
        for scalar in completion.unicodeScalars {
            // Replacement character: the detokenizer produced bytes it could not decode. Never text.
            if scalar == "\u{FFFD}" {
                return false
            }
            // C0 control range and DEL. A line feed is legitimate content in a multi-line completion
            // (the normalizer keeps newlines when multi-line mode is on), so it must pass; any other
            // control character (an interior tab, a stray escape) is corruption, not content.
            if scalar.value != 0x0A, scalar.value < 0x20 || scalar.value == 0x7F {
                return false
            }
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                sawNonWhitespace = true
            }
        }

        // Whitespace-only output is not a completion.
        return sawNonWhitespace
    }
}
