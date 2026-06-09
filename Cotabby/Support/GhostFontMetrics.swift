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
    static func pointSize(
        caretHeight: CGFloat,
        fieldMetrics: FieldFontMetrics?,
        fallbackRatio: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat,
        sizeMultiplier: CGFloat = 1
    ) -> CGFloat {
        let ratio = metricRatio(fieldMetrics) ?? fallbackRatio
        let autoSize = min(max(minimum, caretHeight * ratio), maximum)
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
