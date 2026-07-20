import Foundation

/// File overview:
/// Measures the trailing `:query` (or `:query:`) run at the end of the field's preceding text so the
/// emoji picker knows exactly how many UTF-16 units to delete before inserting the glyph. Measuring
/// the real field text (rather than trusting our own character count) keeps commit robust against
/// our own off-by-ones and against host autocorrect that may have reshaped the literal text.
enum EmojiQueryRun {
    /// UTF-16 length of the trailing `:alias` or `:alias:` run, or nil when the text does not end with
    /// one. AX selection and ranges are UTF-16 indexed, so the length is reported in UTF-16 units to
    /// match what the synthetic backspaces delete.
    static func trailingRunUTF16Length(in precedingText: String) -> Int? {
        let text = precedingText as NSString
        let fullRange = NSRange(location: 0, length: text.length)
        guard let match = Self.regex?.firstMatch(in: precedingText, range: fullRange),
              match.range.length > 0 else {
            return nil
        }
        return match.range.length
    }

    /// `:` then any run of alias characters then an optional closing `:`, anchored to the end of the
    /// preceding text (the caret position).
    private static let regex = try? NSRegularExpression(pattern: ":[A-Za-z0-9_+\\-]*:?$")
}
