import CoreGraphics
import Foundation

/// Derives the ghost-text point size from the measured caret height.
///
/// When the host field's font metrics are known, the ghost text scales by that font's own glyph-box
/// ratio (`pointSize / (ascender - descender)`) so it visually matches the field's text. Different
/// typefaces have different ascender/descender ratios, so a single fixed ratio mis-sizes monospace
/// and display fonts; using the field font's real metrics fixes that. When no field font is available
/// the helper falls back to the previous fixed ratio, preserving prior behavior exactly.
///
/// Kept as a pure value helper (no AppKit) so the sizing math is unit-testable in isolation; callers
/// extract the metrics from an `NSFont` and pass plain numbers.
enum GhostFontMetrics {
    /// Hard legibility floor applied after the user's size multiplier, below which ghost text would
    /// read as broken rather than small. It sits under `minimum` on purpose so a "smaller" multiplier
    /// still shrinks text that auto-sized to the floor; within the shipped multiplier range it never
    /// binds, so it is purely a backstop against degenerate inputs (a non-positive or tiny multiplier).
    static let absoluteMinimumPointSize: CGFloat = 9

    /// Note on what `caretHeight` means, and why this helper does not second-guess the host's font
    /// report. A caret rect measured through `AXBoundsForRange` is the *rendered glyph box*
    /// (`ascender - descender`) in screen points, so it already carries the host's zoom. Multiplying
    /// it by the font's own scale-invariant ratio recovers the on-screen point size directly, which
    /// is why no zoom factor appears anywhere in this file.
    ///
    /// A previous version tried to detect placeholder font reports by testing `caretHeight` against
    /// the glyph box implied by the *reported* point size. That test is unsound: the reported size is
    /// in document units while the caret is in screen units, so any zoom above ~1.45 made an honest
    /// report look like a lie (Word at 164% reports 12pt against a 23pt caret — a ratio of 1.62 that
    /// is entirely zoom). The real defect it was compensating for was a misread typeface, now fixed
    /// at its source in `AXHelper.faceName(fromAXFontDictionary:)`. Do not reintroduce a size-based
    /// trust check here without a scale reference that is in the same units as the caret.
    ///
    /// Glyph-box metrics of the host field's font. `ascender - descender` is the full glyph box
    /// height (`NSFont.descender` is negative). The derived ratio is scale-invariant, so callers may
    /// instantiate the reference font at any size.
    struct FieldFontMetrics: Equatable {
        let pointSize: CGFloat
        let ascender: CGFloat
        let descender: CGFloat
    }

    /// `sizeMultiplier` is the user's Appearance "Ghost Text Size" knob. It scales the
    /// caret-approximated size *after* the `[minimum, maximum]` clamp, so the knob reliably resizes
    /// ghost text even for fields that auto-size onto those rails; applying it before the clamp would
    /// make a "smaller" choice a no-op whenever the field already sits at `minimum`. Growth is bounded
    /// by the caller's clamped multiplier rather than a second ceiling here; only the absolute floor
    /// is re-applied so a low multiplier can never produce illegibly small text.
    ///
    /// `caretHeightIsSynthetic` marks the case where `caretHeight` is not a measurement at all. On
    /// the `AXFrame` fallback path the resolver has no text-range geometry to read, so it fabricates
    /// a caret box from a fixed 15pt system font — a constant ~18pt regardless of what the host is
    /// really rendering. Deriving a font size from that constant is meaningless: it pins ghost text
    /// near 14pt in *every* such host, which is why a zoomed Word document (16pt Aptos at 161% zoom
    /// ≈ 26pt on screen) got ghost text roughly half the size of the user's own text. When the caret
    /// is synthetic and the host told us its real point size, that reported size is genuine
    /// information and the fabricated height is not, so we use the former and ignore the latter.
    ///
    /// `hostReportedPointSize` is passed separately from `fieldMetrics` on purpose. `fieldMetrics`
    /// can only be built when the typeface itself instantiates, and hosts that bundle private fonts
    /// (Word's Aptos) may report a perfectly good *size* alongside a *name* we cannot resolve.
    /// Keeping them apart means a failed typeface lookup no longer throws away the point size too.
    static func pointSize(
        caretHeight: CGFloat,
        caretHeightIsSynthetic: Bool = false,
        fieldMetrics: FieldFontMetrics?,
        hostReportedPointSize: CGFloat? = nil,
        fallbackRatio: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat,
        syntheticCaretMaximum: CGFloat? = nil,
        sizeMultiplier: CGFloat = 1
    ) -> CGFloat {
        let ratio = metricRatio(fieldMetrics) ?? fallbackRatio

        let base: CGFloat
        let ceiling: CGFloat
        if caretHeightIsSynthetic, let reported = hostReportedPointSize, reported > 0 {
            base = reported
            // The tighter `maximum` a synthetic caret normally gets exists to stop one bad *rect*
            // from rendering comically oversized ghost text. A host-reported point size is not a
            // rect estimate, so it earns the looser ceiling — otherwise legitimately large text
            // (zoomed documents, headings) would still be truncated.
            ceiling = syntheticCaretMaximum ?? maximum
        } else {
            base = caretHeight * ratio
            ceiling = maximum
        }

        let autoSize = min(max(minimum, base), ceiling)
        return max(absoluteMinimumPointSize, autoSize * sizeMultiplier)
    }

    /// `pointSize / (ascender - descender)` for the field font, or nil when the metrics are unusable.
    private static func metricRatio(_ metrics: FieldFontMetrics?) -> CGFloat? {
        guard let metrics, metrics.pointSize > 0 else {
            return nil
        }

        let glyphBoxHeight = metrics.ascender - metrics.descender
        guard glyphBoxHeight > 0 else {
            return nil
        }

        return metrics.pointSize / glyphBoxHeight
    }
}
