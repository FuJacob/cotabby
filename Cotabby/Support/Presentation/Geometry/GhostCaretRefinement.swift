import AppKit
import Foundation

/// File overview:
/// Recovers the exact caret x for a web host from typography instead of from the rounded box
/// Accessibility reports.
///
/// WebKit answers `AXBoundsForRange` with pixel-enclosing rects: a caret whose true position is
/// 481.1 comes back as the 482…484 box, and the trailing edge of the previous character is rounded
/// up as well. Measured in Safari, the ghost then started a full point right of where the host put
/// the accepted text. The host did tell us its exact font, though, and the visual line's left edge
/// (also from AX, but CSS boxes sit on whole pixels far more often than glyph edges do). The caret is
/// simply that edge plus the advance of the text on the line, shaped with the same font the host
/// used. The result is only trusted when it lands within a small distance of the reported caret,
/// which is what rules out soft-wrapped paragraphs, where the paragraph text is longer than the
/// visual line.
enum GhostCaretRefinement {
    /// Largest disagreement with the reported caret still attributable to rounding.
    static let maximumAdjustment: CGFloat = 1.5

    struct Input {
        /// Left edge of the host's visual line box, in the same coordinates as `reportedCaretX`.
        let lineLeft: CGFloat
        /// Text between the last hard line break and the caret.
        let paragraphTextBeforeCaret: String
        /// The host's exact typeface at its exact size.
        let font: NSFont
        let reportedCaretX: CGFloat
        let isRightToLeft: Bool
    }

    /// The refined caret x, or nil when the line is wrapped, empty, right-to-left, or the
    /// typographic answer disagrees with the host beyond rounding.
    static func caretX(_ input: Input) -> CGFloat? {
        guard !input.isRightToLeft, !input.paragraphTextBeforeCaret.isEmpty else { return nil }
        let attributed = NSAttributedString(string: input.paragraphTextBeforeCaret, attributes: [.font: input.font])
        let line = CTLineCreateWithAttributedString(attributed)
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        guard advance > 0 else { return nil }
        let refined = input.lineLeft + advance
        guard abs(refined - input.reportedCaretX) <= maximumAdjustment else { return nil }
        return refined
    }

    /// The paragraph text before the caret: everything after the last hard line break.
    static func paragraphTextBeforeCaret(in precedingText: String) -> String {
        if let breakIndex = precedingText.lastIndex(where: { $0.isNewline }) {
            return String(precedingText[precedingText.index(after: breakIndex)...])
        }
        return precedingText
    }
}
