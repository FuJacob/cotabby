import Foundation

/// Last-mile cleanup for full Compose drafts.
///
/// This deliberately does not reuse `SuggestionTextNormalizer`: autocomplete should collapse to one
/// inline fragment, while Compose needs to preserve paragraph boundaries and only remove wrappers.
enum ComposeTextNormalizer {
    private static let leadingLabels = [
        "final answer:",
        "final draft:",
        "draft:",
        "comment:",
        "response:",
        "reply:"
    ]

    static func normalize(
        _ rawText: String,
        prompt: String,
        request: ComposeRequest
    ) -> String {
        var normalized = rawText.replacingOccurrences(of: "\r", with: "")
        normalized = normalized.replacingOccurrences(of: "<|im_end|>", with: "")
        normalized = normalized.replacingOccurrences(of: "<|im_start|>", with: "")

        if !prompt.isEmpty, normalized.hasPrefix(prompt) {
            normalized.removeFirst(prompt.count)
        }

        normalized = normalized.trimmingCharacters(in: .controlCharacters.union(.newlines))
        normalized = stripMarkdownFence(from: normalized)
        normalized = stripLeadingLabel(from: normalized)
        normalized = stripWholeResponseQuotes(from: normalized)
        normalized = stripTypedPrefixEcho(from: normalized, typedPrefix: request.typedPrefix)
        normalized = trimExcessBlankLines(in: normalized)

        return normalized.trimmingCharacters(in: .controlCharacters.union(.newlines))
    }

    private static func stripMarkdownFence(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else {
            return text
        }

        var lines = trimmed.components(separatedBy: .newlines)
        guard let firstLine = lines.first, firstLine.hasPrefix("```") else {
            return text
        }

        lines.removeFirst()
        if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
            lines.removeLast()
        }

        return lines.joined(separator: "\n")
    }

    private static func stripLeadingLabel(from text: String) -> String {
        let trimmedLeading = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmedLeading.lowercased()

        for label in leadingLabels where lowercased.hasPrefix(label) {
            let start = trimmedLeading.index(trimmedLeading.startIndex, offsetBy: label.count)
            return String(trimmedLeading[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return text
    }

    private static func stripWholeResponseQuotes(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            return text
        }

        let quotePairs: [(Character, Character)] = [
            ("\"", "\""),
            ("'", "'")
        ]

        for (opening, closing) in quotePairs
        where trimmed.first == opening && trimmed.last == closing {
            return String(trimmed.dropFirst().dropLast())
        }

        return text
    }

    private static func stripTypedPrefixEcho(from text: String, typedPrefix: String) -> String {
        let trimmedPrefix = typedPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrefix.isEmpty else {
            return text
        }

        let leadingTrimmedText = text.trimmingCharacters(in: .newlines)
        guard leadingTrimmedText.localizedCaseInsensitiveContains(trimmedPrefix),
              leadingTrimmedText.lowercased().hasPrefix(trimmedPrefix.lowercased())
        else {
            return text
        }

        let endIndex = leadingTrimmedText.index(leadingTrimmedText.startIndex, offsetBy: trimmedPrefix.count)
        return String(leadingTrimmedText[endIndex...])
    }

    private static func trimExcessBlankLines(in text: String) -> String {
        var result: [String] = []
        var blankLineCount = 0

        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blankLineCount += 1
                if blankLineCount <= 1 {
                    result.append("")
                }
            } else {
                blankLineCount = 0
                result.append(line.trimmingCharacters(in: .whitespaces))
            }
        }

        return result.joined(separator: "\n")
    }
}
