import Foundation

/// File overview:
/// Curls the straight quotes in a suggestion the way macOS's "Use smart quotes" does, so accepted
/// text matches what the user would have typed by hand. Models emit ASCII `"` and `'`; Cocoa text
/// views substitute them only for real keystrokes, so without this an accepted suggestion leaves
/// straight quotes beside the user's curly ones.
///
/// Pure: the coordinator reads the system preference (`defaultsKey`) and passes the text before the
/// caret, which decides whether a leading quote opens or closes. Applied before the session starts,
/// so the ghost, the typed-through match, and the inserted text all carry the same characters.
enum SmartQuoteSubstitution {
    /// Global-domain key behind System Settings > Keyboard > Text Input > "Use smart quotes and dashes".
    static let defaultsKey = "NSAutomaticQuoteSubstitutionEnabled"

    /// Characters after which a quote opens: start of text, whitespace, and opening brackets/quotes.
    private static let openingContext: Set<Character> = ["(", "[", "{", "<", "“", "‘", "«", "‹", "—", "–"]

    static func apply(_ text: String, precedingText: String) -> String {
        guard text.contains(where: { $0 == "\"" || $0 == "'" }) else { return text }
        var result = ""
        // Each decision reads the character already emitted, so `"'` opens both quotes (“‘).
        var previous = precedingText.last
        for character in text {
            let opens = previous.map { $0.isWhitespace || openingContext.contains($0) } ?? true
            let replacement: Character
            switch character {
            case "\"":
                replacement = opens ? "“" : "”"
            case "'":
                // After a letter it closes, which also makes in-word apostrophes (`don't`) ’, as macOS does.
                replacement = opens ? "‘" : "’"
            default:
                replacement = character
            }
            result.append(replacement)
            previous = replacement
        }
        return result
    }
}
