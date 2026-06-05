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
    /// Glyph-box metrics of the host field's font. `ascender - descender` is the full glyph box
    /// height (`NSFont.descender` is negative). The derived ratio is scale-invariant, so callers may
    /// instantiate the reference font at any size.
    struct FieldFontMetrics: Equatable {
        let pointSize: CGFloat
        let ascender: CGFloat
        let descender: CGFloat
    }

    static func pointSize(
        caretHeight: CGFloat,
        fieldMetrics: FieldFontMetrics?,
        fallbackRatio: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        let ratio = metricRatio(fieldMetrics) ?? fallbackRatio
        let proposed = max(minimum, caretHeight * ratio)
        return min(proposed, maximum)
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
