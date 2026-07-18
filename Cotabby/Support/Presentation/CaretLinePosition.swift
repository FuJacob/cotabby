import Foundation

/// File overview:
/// Pure caret-position rules derived from the text immediately around the caret. Kept out of the
/// focus-capture layer so these signals stay trivially testable and reusable across the suggestion
/// pipeline (gating, prompting, diagnostics) without dragging in AX or runtime state.
enum CaretLinePosition {
    /// Whether the caret sits at the end of its line: only whitespace (if anything) separates it from
    /// the next line break, or it is at the very end of the field.
    ///
    /// This is the precise distinction between "a forward continuation is appropriate" and "the caret
    /// is mid-line, so any completion has to fit between existing text." The latter is exactly the
    /// case fill-in-middle exists for; a bare `trailingText.isEmpty` check misses a caret parked at
    /// the end of a line that still has later paragraphs after the line break.
    static func isAtEndOfLine(trailingText: String) -> Bool {
        for character in trailingText {
            if character.isNewline {
                // Hit the line break with only whitespace seen so far: this line ends at the caret.
                return true
            }
            if !character.isWhitespace {
                return false
            }
        }
        // No line break and nothing but whitespace after the caret: end of the final line.
        return true
    }
}
