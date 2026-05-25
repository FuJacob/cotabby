import AppKit
import SwiftUI

/// File overview:
/// Converts between user-editable ghost-text colors and the hex strings Cotabby persists.
///
/// Why this file exists:
/// Settings wants a native `ColorPicker`, persistence wants a stable text format, and the overlay
/// service wants an AppKit-compatible color it can render immediately. Centralizing the conversion
/// rules here avoids copy-pasting slightly different color math across those layers.
enum SuggestionTextColorCodec {
    static func color(fromHex hex: String?) -> Color? {
        guard let nsColor = nsColor(fromHex: hex) else {
            return nil
        }

        return Color(nsColor: nsColor)
    }

    static func nsColor(fromHex hex: String?) -> NSColor? {
        guard let hex else {
            return nil
        }

        let normalizedHex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let validCharacters = CharacterSet(charactersIn: "0123456789ABCDEFabcdef")
        guard normalizedHex.count == 6,
              normalizedHex.unicodeScalars.allSatisfy(validCharacters.contains(_:))
        else {
            return nil
        }

        var value: UInt64 = 0
        guard Scanner(string: normalizedHex).scanHexInt64(&value) else {
            return nil
        }

        let red = CGFloat((value & 0xFF0000) >> 16) / 255
        let green = CGFloat((value & 0x00FF00) >> 8) / 255
        let blue = CGFloat(value & 0x0000FF) / 255
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    static func hexString(from nsColor: NSColor) -> String? {
        guard let srgbColor = nsColor.usingColorSpace(.sRGB) else {
            return nil
        }

        let red = Int((srgbColor.redComponent * 255).rounded())
        let green = Int((srgbColor.greenComponent * 255).rounded())
        let blue = Int((srgbColor.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", red, green, blue)
    }
}
