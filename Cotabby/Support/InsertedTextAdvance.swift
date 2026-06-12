import AppKit

/// File overview:
/// Measures how far a host field's caret travels when text is inserted, using the field's own
/// resolved font.
///
/// The accept-time overlay slide and the predicted-caret fallback both need the caret's true
/// travel, not the ghost render font's width of the same text. The ghost is deliberately floored
/// at 14pt for legibility while hosts commonly render smaller (TextEdit's Helvetica 12, plain-text
/// Menlo 11), so a ghost-font measurement overshoots the real caret advance by 5-11pt per accepted
/// word. That error lands in the overlay's anchor bookkeeping, accumulates past the stability
/// gate's drift tolerance, and surfaces as a sideways nudge tens of milliseconds after the accept,
/// when no input is happening and any motion reads as jitter. Measuring with the field's own font
/// keeps the anchor aligned with where AX will report the caret once the host publishes the
/// insert, so post-accept reconciles have nothing to correct.
nonisolated enum InsertedTextAdvance {
    /// Width of `text` in the field's resolved font, or nil when the style does not carry a
    /// usable font (callers keep their previous approximation).
    ///
    /// Whitespace is measured as-is: a leading boundary space is real caret travel, so this
    /// deliberately does not share `GhostSuggestionLayout`'s display normalization. A style whose
    /// face name fails to resolve still uses the host's point size with the system face; the size
    /// dominates the width error the ghost-font fallback suffers from.
    static func width(of text: String, style: ResolvedFieldStyle?) -> CGFloat? {
        guard !text.isEmpty, let style, let pointSize = style.fontPointSize, pointSize > 0 else {
            return nil
        }
        let font = style.fontName.flatMap { NSFont(name: $0, size: pointSize) }
            ?? NSFont.systemFont(ofSize: pointSize)
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        guard width.isFinite, width > 0 else {
            return nil
        }
        return width
    }
}
