import Foundation

/// File overview:
/// Turns a model's raw rewrite into text that can replace the selection, or rejects it. Strips the
/// wrappers models add (a preface such as "Here is the rewritten text:", a code fence, quotes
/// around the whole answer), keeps the selection's own leading and trailing whitespace so a
/// replaced line keeps its spacing, and refuses empty output or output too long to be a rewrite.
nonisolated enum RewriteOutputCleaner {
    /// A rewrite at most this many times the selection's length; Shorter may not grow at all.
    static let maximumGrowth = 3

    static func clean(_ raw: String, selection: String, action: RewriteAction) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = stripCodeFence(text)
        // A preface is a wrapper the model added. When the user's own selection opens the same way
        // ("Here is my address: ..."), the model may be echoing it, so the opening stays.
        if !startsWithPreface(selection.trimmingCharacters(in: .whitespacesAndNewlines)) {
            text = stripPreface(text)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !startsWithQuote(selection.trimmingCharacters(in: .whitespacesAndNewlines)) {
            text = stripWrappingQuotes(text)
        }
        guard !text.isEmpty else { return nil }
        let core = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit: Int
        switch action {
        case .shorter: limit = core.count
        // Longer expands a short draft into a full message, so a few words may become a paragraph.
        case .longer: limit = core.count * 8 + 400
        default: limit = core.count * maximumGrowth + 40
        }
        guard text.count <= limit else { return nil }
        let leading = String(selection.prefix(while: { $0.isWhitespace }))
        let trailing = String(selection.reversed().prefix(while: { $0.isWhitespace }).reversed())
        return leading + text + trailing
    }

    private static func stripCodeFence(_ text: String) -> String {
        guard text.hasPrefix("```"), text.hasSuffix("```"), text.count >= 6 else { return text }
        var lines = text.components(separatedBy: "\n")
        lines.removeFirst()
        if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// "Here is…:", "Here's a friendlier version:", "Sure! …:", "Rewritten text:", "Rewritten:".
    /// Anchored at the start, so only an opening preface matches.
    private static let prefacePattern = #"^(?:(?:sure|certainly|of course)[!.,]?\s*)?"#
        + #"(?:here(?:'s| is)[^:\n]{0,60}:|rewritten(?: text| version)?:)\s*"#

    private static func stripPreface(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: prefacePattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    /// Whether the (trimmed) selection itself opens with a preface-like phrase, using the same pattern.
    private static func startsWithPreface(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: prefacePattern, options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let quotePairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'"), ("«", "»")]

    private static func startsWithQuote(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return quotePairs.contains { $0.0 == first }
    }

    private static func stripWrappingQuotes(_ text: String) -> String {
        guard let first = text.first, let last = text.last, text.count >= 2,
              quotePairs.contains(where: { $0.0 == first && $0.1 == last }) else { return text }
        return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
