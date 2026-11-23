import Foundation

/// Removes secret-like strings from text before it enters typing history.
///
/// History is stored for months and fed back into prompts, so a pasted API key, private key, or
/// card number must not survive into it, even though the archive is encrypted and only on-device
/// engines read it.
/// The rules are deliberately conservative about prose: ordinary words, names, and short numbers
/// pass through untouched. Only shapes that are almost never written by hand are replaced, plus a
/// value that its own label marks as secret ("password: …", "token=…", "verification code 123456").
/// A secret typed with no label or recognizable shape (a short password on a line of its own) still
/// passes; that is the cost of not redacting ordinary writing.
nonisolated enum TypingHistoryScrubber {
    static let redaction = "[redacted]"

    /// Records longer than this keep only their tail. History is used for the user's recent wording,
    /// and a 50k-character document would otherwise dominate retrieval and memory.
    static let maximumRecordCharacters = 12_000

    private static let privateKeyBlock = try? NSRegularExpression(
        pattern: "-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)"
    )
    /// Known credential prefixes followed by a run of key characters. The prefix is distinctive
    /// enough that the run can be shorter than `longMixedToken`'s 24 characters, and need not mix
    /// in digits: OpenAI/Anthropic `sk-` (`sk-proj-`, `sk-ant-`), GitHub `gh?_`/`github_pat_`,
    /// GitLab `glpat-`, Slack `xox?-`/`xapp-`, AWS `AKIA`/`ASIA` key ids, Google `AIza`, Hugging
    /// Face `hf_`, npm `npm_`, PyPI `pypi-AgE`, Shopify `shp??_`, and Stripe secret and restricted
    /// keys. `ASIA` must end the token, since an all-caps word can start with it; `pypi-` is only
    /// matched with the `AgE` every PyPI token starts with, so package names like `pypi-server` stay.
    private static let prefixedCredential = try? NSRegularExpression(
        pattern: #"\b(sk-[A-Za-z0-9_\-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}"#
            + #"|glpat-[A-Za-z0-9_\-]{20,}|xox[abprs]-[A-Za-z0-9\-]{10,}|xapp-[A-Za-z0-9\-]{10,}"#
            + #"|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}\b|AIza[0-9A-Za-z_\-]{35}|hf_[A-Za-z0-9]{30,}"#
            + #"|npm_[A-Za-z0-9]{36}|pypi-AgE[A-Za-z0-9_\-]{16,}|shp(?:at|ca|pa|ss)_[A-Fa-f0-9]{32}"#
            + #"|[rs]k_(?:live|test)_[A-Za-z0-9]{16,})"#
    )
    /// US Social Security numbers in their written form. The dashes are required: nine bare digits
    /// are far more often an order or account reference.
    private static let socialSecurityNumber = try? NSRegularExpression(pattern: #"\b\d{3}-\d{2}-\d{4}\b"#)
    /// A secret written next to its label ("password: hunter2", "DB_PASSWORD=…", `"token": "…"`).
    /// Only the value (capture group 1) is replaced, so the sentence around it still reads. The
    /// label must be followed by ":" or "=", which prose rarely puts straight after these words
    /// ("I forgot my password" stays). The label may follow `_` or `-` (`GITHUB_TOKEN=`), but not a
    /// letter or digit, and the value ends at whitespace unless it is quoted.
    private static let labelledSecret = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])(?:pass(?:word|wd|code|phrase)|pwd|secret|client[_-]?secret|secret[_-]?key"#
            + #"|(?:access|refresh|auth|api|bearer)?[_-]?token|api[_-]?key|private[_-]?key)"#
            + #"["']?[ \t]*[:=][ \t]*("[^"\n]*"|'[^'\n]*'|[^\s"']+)"#,
        options: [.caseInsensitive]
    )
    /// A one-time or verification code, only where a label says it is one: "OTP 123456", "your
    /// verification code is 482913", "code: 123456", "PIN: 4821". A bare number is never touched,
    /// since six digits are an order number, amount, or postcode far more often than a code. Plain
    /// "code" and "pin" need ":" , "=" or "is" before the digits ("error code 404" stays). Only the
    /// digits (capture group 1) are replaced.
    private static let labelledCode = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])(?:(?:otp|totp|2fa|mfa|one[- ]time (?:pass)?code|one[- ]time password"#
            + #"|verification code|security code|confirmation code|login code|sign[- ]in code"#
            + #"|auth(?:entication)? code)(?:[ \t]+code)?(?:[ \t]+is|[ \t]*[:=#-])?"#
            + #"|(?:code|pin)[ \t]*(?:[:=]|is\b))[ \t]*(\d{3}[ -]\d{3}|\d{3,8})\b"#,
        options: [.caseInsensitive]
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

    /// Replaces every secret-like span and reports where `boundary` (a UTF-16 offset into `text`)
    /// lands in the result.
    private static func redact(_ text: String, boundary: Int) -> (text: String, boundary: Int) {
        var result = (text: text, boundary: boundary)
        for expression in [privateKeyBlock, prefixedCredential, longDigitRun, socialSecurityNumber].compactMap({ $0 }) {
            result = replaceMatches(of: expression, in: result.text, boundary: result.boundary) { _, _ in redaction }
        }
        // After the whole-token rules, so a value they already replaced is left as it is.
        for expression in [labelledSecret, labelledCode].compactMap({ $0 }) {
            result = replaceMatches(of: expression, in: result.text, boundary: result.boundary, transform: redactingValue)
        }
        if let longMixedToken {
            result = replaceMatches(of: longMixedToken, in: result.text, boundary: result.boundary) { _, token in
                // Long all-letter runs are real words in agglutinative languages (Turkish, German
                // compounds); only runs carrying digits look like generated secrets.
                token.contains(where: \.isNumber) && token.contains(where: \.isLetter) ? redaction : token
            }
        }
        return result
    }

    /// A labelled match with only its value (capture group 1) replaced, so "password: hunter2"
    /// becomes "password: [redacted]" rather than losing the label too.
    private static func redactingValue(_ match: NSTextCheckingResult, token: String) -> String {
        let value = match.range(at: 1)
        guard value.location != NSNotFound else { return redaction }
        let local = NSRange(location: value.location - match.range.location, length: value.length)
        return (token as NSString).replacingCharacters(in: local, with: redaction)
    }

    /// Rewrites each match with `transform` (given the match and its text) and carries `boundary`
    /// (UTF-16) across the edits. A boundary inside a match that is replaced moves to the end of
    /// the replacement, so the secret is never split; inside a match that is kept, it keeps its place.
    private static func replaceMatches(
        of expression: NSRegularExpression,
        in text: String,
        boundary: Int,
        transform: (NSTextCheckingResult, String) -> String
    ) -> (text: String, boundary: Int) {
        let nsText = text as NSString
        var output = ""
        var outputLength = 0
        var mappedBoundary: Int?
        var cursor = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            let range = match.range
            let token = nsText.substring(with: range)
            let replacement = transform(match, token)
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
