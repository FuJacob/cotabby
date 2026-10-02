import Foundation

/// Removes secret-like strings from text before it enters typing history.
///
/// History is stored for months and fed back into prompts, so a pasted API key or private key must
/// not survive into it, even though the archive is encrypted and only on-device engines read it.
/// The rules are deliberately conservative about prose: ordinary words, names, and short numbers
/// pass through untouched, and only shapes that are almost never written by hand are replaced.
nonisolated enum TypingHistoryScrubber {
    static let redaction = "[redacted]"

    /// Records longer than this keep only their tail. History is used for the user's recent wording,
    /// and a 50k-character document would otherwise dominate retrieval and memory.
    static let maximumRecordCharacters = 12_000

    private static let privateKeyBlock = try? NSRegularExpression(
        pattern: "-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)"
    )
    /// Known credential prefixes followed by a run of key characters (OpenAI/Anthropic `sk-`,
    /// GitHub `ghp_`/`gho_`/`github_pat_`, Slack `xox?-`, AWS access key ids).
    private static let prefixedCredential = try? NSRegularExpression(
        pattern: "\\b(sk-[A-Za-z0-9_\\-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}"
            + "|xox[abprs]-[A-Za-z0-9\\-]{10,}|AKIA[0-9A-Z]{16})"
    )
    /// Any long unbroken token mixing letters and digits: JWTs, hex digests, base64 secrets. 24
    /// characters is longer than nearly every real word or identifier a person types.
    private static let longMixedToken = try? NSRegularExpression(
        pattern: "[A-Za-z0-9_\\-+/=.]{24,}"
    )

    /// Scrubs the text before and after the caret separately and caps the pair, so the boundary
    /// between what the user typed and what was already there survives (`TypingHistoryRecord.typedLength`).
    /// When the field is too long, the typed side keeps its end (nearest the caret) and the rest
    /// keeps its start, the same "around the caret" window a reader would care about.
    static func scrub(before: String, after: String) -> (text: String, typedLength: Int) {
        var typed = scrub(before)
        var rest = scrub(after)
        let afterBudget = min(rest.count, maximumRecordCharacters / 6)
        if typed.count + rest.count > maximumRecordCharacters {
            rest = String(rest.prefix(afterBudget))
            typed = String(typed.suffix(maximumRecordCharacters - rest.count))
        }
        while typed.first?.isWhitespace == true { typed.removeFirst() }
        while rest.last?.isWhitespace == true { rest.removeLast() }
        if rest.isEmpty {
            while typed.last?.isWhitespace == true { typed.removeLast() }
        }
        return (typed + rest, typed.count)
    }

    static func scrub(_ text: String) -> String {
        var result = text
        for expression in [privateKeyBlock, prefixedCredential].compactMap({ $0 }) {
            result = replace(expression, in: result)
        }
        if let longMixedToken {
            result = replaceMatches(of: longMixedToken, in: result) { token in
                // Long all-letter runs are real words in agglutinative languages (Turkish, German
                // compounds); only runs carrying digits look like generated secrets.
                token.contains(where: \.isNumber) && token.contains(where: \.isLetter) ? redaction : token
            }
        }
        if result.count > maximumRecordCharacters {
            result = String(result.suffix(maximumRecordCharacters))
        }
        return result
    }

    private static func replace(_ expression: NSRegularExpression, in text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: redaction)
    }

    private static func replaceMatches(
        of expression: NSRegularExpression,
        in text: String,
        transform: (String) -> String
    ) -> String {
        let nsText = text as NSString
        var output = ""
        var cursor = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            output += nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += transform(nsText.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        output += nsText.substring(from: cursor)
        return output
    }
}
