import Foundation

/// Detects whether text near the caret is Right-to-Left by examining Unicode bidi properties.
///
/// The detector walks the string backwards because the characters closest to the caret are the
/// strongest signal for which direction the ghost text should render. Falls back to LTR when
/// no strong directional character is found.
enum TextDirectionDetector {
    /// Returns `true` when the dominant script near the end of `text` is Right-to-Left
    /// (Arabic, Hebrew, or another RTL script).
    static func isRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars.reversed() {
            if isStrongRTL(scalar) { return true }
            if isStrongLTR(scalar) { return false }
        }
        return false
    }

    // MARK: - Unicode bidi classification

    private static func isStrongRTL(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        // Hebrew (0590–05FF), Arabic (0600–06FF), Syriac (0700–074F),
        // Arabic Supplement (0750–077F), Thaana (0780–07BF), NKo (07C0–07FF),
        // Arabic Extended (0870–08FF) — one contiguous test
        if value >= 0x0590 && value <= 0x08FF { return true }
        // Arabic/Hebrew presentation forms + Arabic Presentation Forms-B
        if value >= 0xFB1D && value <= 0xFDFF { return true }
        if value >= 0xFE70 && value <= 0xFEFF { return true }
        // RTL marks
        if value == 0x200F || value == 0x061C { return true }
        return false
    }

    private static func isStrongLTR(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        // Basic Latin letters
        if value >= 0x0041 && value <= 0x005A { return true }
        if value >= 0x0061 && value <= 0x007A { return true }
        // Latin Extended
        if value >= 0x00C0 && value <= 0x024F { return true }
        // Greek
        if value >= 0x0370 && value <= 0x03FF { return true }
        // Cyrillic
        if value >= 0x0400 && value <= 0x04FF { return true }
        // CJK Unified Ideographs (treated as LTR)
        if value >= 0x4E00 && value <= 0x9FFF { return true }
        // LTR mark
        if value == 0x200E { return true }
        return false
    }
}
