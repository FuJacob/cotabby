import AppKit

/// File overview:
/// Turns the font matched to the host into the bold and/or italic face the user asked suggestions
/// to be drawn in (Settings → Appearance).
///
/// Why this file exists:
/// `GhostFontResolver` answers "which font does the host draw in", and that answer must stay plain:
/// the overlay also uses it to measure the host's own text (caret refinement, the advance of an
/// accepted word, typeface calibration). Styling is a separate, presentation-only step applied to a
/// copy of that font just before glyphs are laid out, so a bold ghost never moves the caret math.
///
/// The styled face comes from the host's own family when it has one (Helvetica Neue Bold, Menlo
/// Italic), because a matching face keeps the ghost visually related to the text around it. A family
/// with no such face falls back to the system face at the same size (bold), or to a slanted copy of
/// the same face (italic, a synthetic oblique), so the setting always has a visible effect.
nonisolated enum GhostFontStyler {
    /// Shear for the synthetic oblique, about 12 degrees: the slant of a typical true italic.
    static let syntheticObliqueShear: CGFloat = 0.21

    /// Returns `font` unchanged when neither style is requested.
    static func styled(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
        var result = font
        if bold {
            result = boldFace(of: result)
        }
        if italic {
            result = italicFace(of: result)
        }
        return result
    }

    /// Whether `font` carries the bold trait (a real bold face, or the system face at a bold weight).
    static func isBold(_ font: NSFont) -> Bool {
        font.fontDescriptor.symbolicTraits.contains(.bold)
    }

    /// Whether `font` is italic: a true italic face, or a synthetic oblique made by this type.
    static func isItalic(_ font: NSFont) -> Bool {
        font.fontDescriptor.symbolicTraits.contains(.italic) || hasObliqueTransform(font)
    }

    private static func boldFace(of font: NSFont) -> NSFont {
        // `NSFontManager.convert(_:toHaveTrait:)` looks for the bold member of the same family and
        // returns the font unchanged when the family has none, so the trait is checked afterwards
        // rather than trusted.
        let converted = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        if isBold(converted) {
            return converted
        }
        return NSFont.systemFont(ofSize: font.pointSize, weight: .bold)
    }

    private static func italicFace(of font: NSFont) -> NSFont {
        let converted = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        if converted.fontDescriptor.symbolicTraits.contains(.italic) {
            return converted
        }
        // No italic member: shear the same face. `textTransform` carries the point size in its
        // diagonal, so the size is folded into the matrix rather than passed separately.
        let size = font.pointSize
        let transform = AffineTransform(m11: size, m12: 0, m21: syntheticObliqueShear * size, m22: size, tX: 0, tY: 0)
        return NSFont(descriptor: font.fontDescriptor, textTransform: transform) ?? font
    }

    /// A synthetic oblique shows only in the text matrix: its descriptor still names the upright face.
    private static func hasObliqueTransform(_ font: NSFont) -> Bool {
        font.textTransform.m21 != 0
    }
}
