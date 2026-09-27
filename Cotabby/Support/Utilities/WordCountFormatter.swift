import Foundation

/// Formats word counts for compact display in the menu bar.
enum WordCountFormatter {
    /// Returns a compact string for a word count, or `nil` when the count should not be shown.
    ///
    /// - 0 → `nil` (hide the badge)
    /// - 1–999 → `"1"` … `"999"`
    /// - 1,000–9,949 → `"1.0K"` … `"9.9K"`; 9,950–9,999 rounds up to `"10.0K"`
    /// - 10,000–999,999 → `"10K"` … `"999K"` (whole thousands, truncated)
    /// - 1,000,000–9,999,999 → `"1.0M"` … `"10.0M"`, rounded half-up like the thousands tier
    /// - 10,000,000+ → `"10M"` … (whole millions, truncated)
    static func compactLabel(for count: Int) -> String? {
        guard count > 0 else { return nil }

        if count < 1_000 {
            return "\(count)"
        }

        if count < 10_000 {
            return oneDecimalLabel(count, unit: 1_000, suffix: "K")
        }

        if count < 1_000_000 {
            return "\(count / 1_000)K"
        }

        if count < 10_000_000 {
            return oneDecimalLabel(count, unit: 1_000_000, suffix: "M")
        }
        return "\(count / 1_000_000)M"
    }

    /// Rounds half-up to one decimal using integer tenths. Formatting `Double(count) / unit` with
    /// `%.1f` instead would misround boundaries: 9,950 / 1,000 is stored as 9.9499…, printing
    /// "9.9K" rather than the documented "10.0K", and exact halves such as 1.25 round to even.
    private static func oneDecimalLabel(_ count: Int, unit: Int, suffix: String) -> String {
        let tenths = (count + unit / 20) / (unit / 10)
        return "\(tenths / 10).\(tenths % 10)\(suffix)"
    }
}
