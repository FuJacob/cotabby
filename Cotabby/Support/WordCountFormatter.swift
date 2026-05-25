import Foundation

/// Formats word counts for compact display in the menu bar.
enum WordCountFormatter {
    /// Returns a compact string for a word count, or `nil` when the count should not be shown.
    ///
    /// - 0 → `nil` (hide the badge)
    /// - 1–999 → `"1"` … `"999"`
    /// - 1,000–9,949 → `"1.0K"` … `"9.9K"`; 9,950–9,999 rounds up to `"10.0K"`
    /// - 10,000+ → `"10K"` … `"999K"` … `"1.0M"` etc.
    static func compactLabel(for count: Int) -> String? {
        guard count > 0 else { return nil }

        if count < 1_000 {
            return "\(count)"
        }

        if count < 10_000 {
            let thousands = Double(count) / 1_000
            return String(format: "%.1fK", thousands)
        }

        if count < 1_000_000 {
            return "\(count / 1_000)K"
        }

        let millions = Double(count) / 1_000_000
        if millions < 10 {
            return String(format: "%.1fM", millions)
        }
        return "\(count / 1_000_000)M"
    }
}
