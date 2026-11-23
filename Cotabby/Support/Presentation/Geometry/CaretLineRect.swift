import CoreGraphics

extension CGRect {
    /// Whether this caret rect describes a line an overlay can be placed against. Only its height
    /// and position are checked: a caret box is legitimately zero points wide (Chromium's
    /// text-marker carets, many AppKit insertion points, an empty field's zero-length
    /// `AXBoundsForRange` as in WhatsApp's composer), and `CGRect.isEmpty` calls any rect with a
    /// zero side empty. Read that way, the field-edge icon was hidden in exactly the empty field
    /// where it matters most, and every mid-line card in Gmail's compose body was anchored under
    /// the whole body instead of the caret, 440pt below it (measured 2026-09-11, 13 presentations).
    /// Only a caret with no height (the all-zero rect some hosts publish right after focus) or a
    /// non-finite position is none.
    nonisolated var describesCaretLine: Bool {
        !isNull && height > 0 && minX.isFinite && minY.isFinite && height.isFinite
    }
}
