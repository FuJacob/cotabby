import AppKit

/// File overview:
/// Recognizes a caret the host has not yet moved for text it has already published.
///
/// Why this exists: a Chromium editor publishes a keystroke's text before its caret. Measured
/// 2026-09-11 in Claude's Code composer, the first letter of a message ("K") was in the field's
/// value while the text-marker caret still sat where the empty paragraph began, x 342, in the empty
/// line's 22pt box; the suggestion for "K" arrived before the caret moved and was drawn from it
/// for nine presentations (about 150ms): over the "K" itself, and in the system face at 18.5pt,
/// sized from that 22pt box because no remembered face was filed under it. The next snapshot had
/// the caret after the "K" and everything right.
///
/// The rule: a caret at its line's leading edge while the text before it on that line is not
/// empty cannot be the caret of that text, provided the text is too short to have wrapped (a
/// caret legitimately starts a visual line only at a wrap). Whitespace alone decides nothing, since
/// some hosts collapse a leading space. The presentation waits for the next snapshot instead.
///
/// Pure; `OverlayController` asks it before presenting.
enum CaretLagPolicy {
    /// Points past the line's leading edge within which a caret counts as at the edge; a real caret
    /// after any glyph sits a glyph's advance, several points, further in.
    static let edgeTolerance: CGFloat = 1
    /// Fraction of the line's width the text must stay under to be sure it did not wrap.
    static let oneLineFraction: CGFloat = 0.8

    /// True when `caretX` is at the line's leading edge (`lineLeft`) although `textBeforeCaretOnLine`
    /// holds a glyph that, laid out in `font`, fits well inside `lineWidth`. Right-to-left lines are
    /// not judged.
    static func caretLagsTypedText(
        caretX: CGFloat,
        lineLeft: CGFloat,
        lineWidth: CGFloat,
        textBeforeCaretOnLine: String,
        font: NSFont,
        isRightToLeft: Bool
    ) -> Bool {
        guard !isRightToLeft, lineWidth > 0,
              textBeforeCaretOnLine.contains(where: { !$0.isWhitespace && !$0.isNewline }),
              abs(caretX - lineLeft) <= edgeTolerance
        else { return false }
        let advance = GhostFontResolver.width(of: textBeforeCaretOnLine, font: font)
        return advance > 0 && advance < lineWidth * oneLineFraction
    }
}
