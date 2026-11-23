import AppKit
import SwiftUI

/// File overview:
/// The fixed colors of a suggestion's chrome: the green that marks a typo correction, the gray
/// ghost text falls back to when neither the user nor the host field names a color, and the
/// accept-key pill's colors.
///
/// One suggestion can be drawn by two renderers: `GhostTextPanelView` paints inline ghost text
/// with AppKit, and `MirrorOverlayView` draws the card in SwiftUI. Each used to carry its own copy
/// of these numbers; here both take them from one place, so a correction reads the same green and
/// the pill the same gray in either display mode.
///
/// Each color is offered as the type its renderer draws with, built the way that renderer always
/// built it (grays as `NSColor(white:)` for AppKit and `Color(white:)` for SwiftUI) rather than
/// converted from one to the other: the two initializers name different gray color spaces, and a
/// conversion would shift the rendered value by a fraction of a level.
nonisolated enum GhostTextPalette {
    private struct RGB {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
    }

    /// Tuned per appearance so the correction stays legible on both light and dark field
    /// backgrounds. The user's custom suggestion color is deliberately bypassed for corrections:
    /// "this replaces a typo" is semantic, and must not be recolored into ordinary ghost text.
    private static func correctionRGB(dark: Bool) -> RGB {
        dark ? RGB(red: 0.45, green: 0.85, blue: 0.45) : RGB(red: 0.15, green: 0.60, blue: 0.20)
    }

    private static func automaticTextWhite(dark: Bool) -> CGFloat { dark ? 0.65 : 0.45 }
    private static func keycapBackgroundWhite(dark: Bool) -> CGFloat { dark ? 0.18 : 0.95 }
    private static func keycapBorderWhite(dark: Bool) -> CGFloat { dark ? 0.3 : 0.8 }

    // MARK: AppKit (inline ghost text)

    static func correction(dark: Bool) -> NSColor {
        let rgb = correctionRGB(dark: dark)
        return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    /// The adaptive gray for ghost text (and the pill's label) when no other color applies.
    static func automaticText(dark: Bool) -> NSColor {
        NSColor(white: automaticTextWhite(dark: dark), alpha: 1)
    }

    static func keycapBackground(dark: Bool) -> NSColor {
        NSColor(white: keycapBackgroundWhite(dark: dark), alpha: 1)
    }

    static func keycapBorder(dark: Bool) -> NSColor {
        NSColor(white: keycapBorderWhite(dark: dark), alpha: 1)
    }

    // MARK: SwiftUI (the card)

    static func correctionColor(dark: Bool) -> Color {
        let rgb = correctionRGB(dark: dark)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    static func automaticTextColor(dark: Bool) -> Color {
        Color(white: automaticTextWhite(dark: dark))
    }

    static func keycapBackgroundColor(dark: Bool) -> Color {
        Color(white: keycapBackgroundWhite(dark: dark))
    }

    static func keycapBorderColor(dark: Bool) -> Color {
        Color(white: keycapBorderWhite(dark: dark))
    }
}
