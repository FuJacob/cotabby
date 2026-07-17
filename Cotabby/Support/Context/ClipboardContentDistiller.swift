import Foundation

/// Extracts only the clipboard lines that share meaningful tokens with the user's current
/// prefix text. Short clipboard content passes through unchanged; longer content is filtered
/// to the lines most likely to help the autocomplete model.
enum ClipboardContentDistiller {
    private static let compactLineThreshold = 3
    private static let headFallbackCharacters = 300

    /// Returns a distilled version of `clipboard` containing only lines relevant to `prefixText`.
    ///
    /// - Clipboard with ≤3 lines or empty `prefixText` is returned as-is.
    /// - Longer clipboard keeps only lines whose tokens overlap with `prefixText`.
    /// - If no individual line overlaps, the first 300 characters are returned as a head fallback.
    static func distill(clipboard: String, prefixText: String) -> String {
        let lines = clipboard.components(separatedBy: "\n")
        guard lines.count > compactLineThreshold else { return clipboard }

        let prefixTokens = PromptContextSanitizer.significantTokens(from: prefixText)
        guard !prefixTokens.isEmpty else { return clipboard }

        let relevantLines = lines.filter { line in
            let lineTokens = PromptContextSanitizer.significantTokens(from: line)
            return !lineTokens.isDisjoint(with: prefixTokens)
        }

        if relevantLines.isEmpty {
            return String(clipboard.prefix(headFallbackCharacters))
        }

        return relevantLines.joined(separator: "\n")
    }
}
