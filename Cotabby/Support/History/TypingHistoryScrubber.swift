import Foundation

/// Removes secret-like strings from text before it enters typing history.
///
/// History is stored for months and fed back into prompts, so a pasted API key, private key, or
/// card number must not survive into it, even though the archive is encrypted and only on-device
/// engines read it.
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
    /// Card-number-length digit runs (13 to 19 digits, optionally grouped by single spaces or
    /// dashes). Payment fields on websites are ordinary text fields, not secure ones, so a typed
    /// card number reaches the recorder like any other text. Phone numbers stay below 13 digits.
    private static let longDigitRun = try? NSRegularExpression(
        pattern: "\\b(?:\\d[ \\-]?){12,18}\\d\\b"
    )
    /// Any long unbroken token mixing letters and digits: JWTs, hex digests, base64 secrets. 24
    /// characters is longer than nearly every real word or identifier a person types.
    private static let longMixedToken = try? NSRegularExpression(
        pattern: "[A-Za-z0-9_\\-+/=.]{24,}"
    )

    /// Scrubs the text before and after the caret and caps the pair, so the boundary between what
    /// the user typed and what was already there survives (`TypingHistoryRecord.typedLength`).
    ///
    /// Both sides are scrubbed as one text. Scrubbed separately, a caret inside a pasted key would
    /// split it into two halves that are each too short to look like a secret, and joining them
    /// again would store the whole key. A secret that straddles the caret is redacted whole and
    /// counts as typed. When the field is too long, the typed side keeps its end (nearest the caret)
    /// and the rest keeps its start, the same "around the caret" window a reader would care about.
    static func scrub(before: String, after: String) -> (text: String, typedLength: Int) {
        let redacted = redact(before + after, boundary: before.utf16.count)
        let split = String.Index(utf16Offset: redacted.boundary, in: redacted.text)
        var typed = String(redacted.text[..<split])
        var rest = String(redacted.text[split...])
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
        let result = redact(text, boundary: 0).text
        guard result.count > maximumRecordCharacters else { return result }
        return String(result.suffix(maximumRecordCharacters))
    }

    /// Replaces every secret-like span and reports where `boundary` (a UTF-16 offset into `text`)
    /// lands in the result.
    private static func redact(_ text: String, boundary: Int) -> (text: String, boundary: Int) {
        var result = (text: text, boundary: boundary)
        for expression in [privateKeyBlock, prefixedCredential, longDigitRun].compactMap({ $0 }) {
            result = replaceMatches(of: expression, in: result.text, boundary: result.boundary) { _ in redaction }
        }
        if let longMixedToken {
            result = replaceMatches(of: longMixedToken, in: result.text, boundary: result.boundary) { token in
                // Long all-letter runs are real words in agglutinative languages (Turkish, German
                // compounds); only runs carrying digits look like generated secrets.
                token.contains(where: \.isNumber) && token.contains(where: \.isLetter) ? redaction : token
            }
        }
        return result
    }

    /// Rewrites each match with `transform` and carries `boundary` (UTF-16) across the edits. A
    /// boundary inside a match that is replaced moves to the end of the replacement, so the secret
    /// is never split; inside a match that is kept, it keeps its place.
    private static func replaceMatches(
        of expression: NSRegularExpression,
        in text: String,
        boundary: Int,
        transform: (String) -> String
    ) -> (text: String, boundary: Int) {
        let nsText = text as NSString
        var output = ""
        var outputLength = 0
        var mappedBoundary: Int?
        var cursor = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            let range = match.range
            let token = nsText.substring(with: range)
            let replacement = transform(token)
            let unchangedLength = range.location - cursor
            if mappedBoundary == nil, boundary < range.location + range.length {
                mappedBoundary = boundary <= range.location || replacement == token
                    ? outputLength + boundary - cursor
                    : outputLength + unchangedLength + (replacement as NSString).length
            }
            output += nsText.substring(with: NSRange(location: cursor, length: unchangedLength))
            output += replacement
            outputLength += unchangedLength + (replacement as NSString).length
            cursor = range.location + range.length
        }
        output += nsText.substring(from: cursor)
        return (output, mappedBoundary ?? outputLength + boundary - cursor)
    }
}
