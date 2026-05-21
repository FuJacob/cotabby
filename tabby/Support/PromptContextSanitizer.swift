import Foundation

/// File overview:
/// Sanitizes auxiliary prompt context that Tabby did not get from the focused text field itself.
///
/// Clipboard text and OCR text can contain terminal separators, Markdown fences, shell prompts,
/// ANSI color escapes, and other prompt-shaped symbols. Those tokens are not useful semantic
/// context for autocomplete, and small local models can copy them back as output. Keeping this as
/// a pure `Support/` helper makes the policy deterministic, shared, and easy to test.
enum PromptContextSanitizer {
    private static let ansiEscapePattern = "\u{001B}\\[[0-?]*[ -/]*[@-~]"
    private static let allowedCharacters = CharacterSet.alphanumerics
        .union(.whitespacesAndNewlines)
        .union(CharacterSet(charactersIn: "@."))
    private static let replacementScalar = UnicodeScalar(" ")

    /// Returns prompt-safe context containing only letters, numbers, whitespace, `@`, and `.`.
    ///
    /// Disallowed scalars become spaces instead of being deleted. That preserves word boundaries:
    /// `raw-output` becomes `raw output`, not `rawoutput`. The final line pass collapses repeated
    /// whitespace so stripped punctuation cannot still dominate the prompt through spacing noise.
    static func sanitize(_ rawText: String, maxCharacters: Int? = nil) -> String {
        let withoutANSIEscapes = rawText.replacingOccurrences(
            of: ansiEscapePattern,
            with: " ",
            options: .regularExpression
        )

        let sanitizedScalars = withoutANSIEscapes.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? scalar : replacementScalar
        }

        let sanitizedText = String(String.UnicodeScalarView(sanitizedScalars))
        let normalizedLines = sanitizedText
            .components(separatedBy: .newlines)
            .map { collapseInlineWhitespace(in: $0) }
            .filter { !$0.isEmpty }

        let normalizedText = normalizedLines.joined(separator: "\n")
        let boundedText = maxCharacters.map {
            String(normalizedText.prefix($0))
        } ?? normalizedText

        return boundedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stricter sanitization for OCR text headed to the summarizer. On top of the base sanitize
    /// pass, this drops single/two-character noise tokens and standalone numbers that come from
    /// UI chrome (PID numbers, CPU percentages, pixel dimensions). Lines that become mostly empty
    /// after filtering are dropped entirely.
    static func sanitizeOCR(_ rawText: String, maxCharacters: Int? = nil) -> String {
        let baseSanitized = sanitize(rawText, maxCharacters: nil)
        let filteredLines = baseSanitized
            .components(separatedBy: .newlines)
            .compactMap { filterOCRNoiseLine($0) }

        let joined = filteredLines.joined(separator: "\n")
        let bounded = maxCharacters.map { String(joined.prefix($0)) } ?? joined
        return bounded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func containsAlphanumericSignal(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// Common 1-2 character English words that should survive OCR noise filtering.
    private static let preservedShortWords: Set<String> = [
        "a", "i", "an", "am", "as", "at", "be", "by", "do", "go", "he",
        "if", "in", "is", "it", "me", "my", "no", "of", "on", "or", "so",
        "to", "up", "us", "we"
    ]

    /// Filters a single OCR line: drops short noise tokens and standalone numbers, then drops
    /// the entire line if fewer than half its original tokens survived.
    private static func filterOCRNoiseLine(_ line: String) -> String? {
        let tokens = line.components(separatedBy: " ").filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        let kept = tokens.filter { token in
            // Drop standalone numbers (UI chrome: "50", "424", "102")
            if token.allSatisfy(\.isNumber) { return false }
            // Keep common short English words; drop other 1-2 char noise ("l", "I", "iD3")
            if token.count <= 2 {
                return preservedShortWords.contains(token.lowercased())
            }
            return true
        }

        // If more than half the tokens were noise, the whole line is probably UI chrome.
        guard kept.count * 2 >= tokens.count else { return nil }

        let result = kept.joined(separator: " ")
        return result.isEmpty ? nil : result
    }

    private static func collapseInlineWhitespace(in line: String) -> String {
        let normalized = line.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
