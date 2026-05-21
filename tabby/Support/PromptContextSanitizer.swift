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

    static func containsAlphanumericSignal(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
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
