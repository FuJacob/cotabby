import Foundation

/// File overview:
/// Sanitizes auxiliary prompt context that Cotabby did not get from the focused text field itself.
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

    /// Stricter sanitization for OCR text headed to the summarizer.
    ///
    /// OCR adds a second failure mode beyond ordinary prompt injection: Vision can hallucinate
    /// short mixed-case blobs, random alphanumeric IDs, repeated glyphs, and numeric UI chrome.
    /// Those fragments are especially harmful for autocomplete because the model may copy them as
    /// the next token. The line pass below keeps real prose and technical terms, but drops a line
    /// when most of its original tokens score as OCR noise.
    static func sanitizeOCR(_ rawText: String, maxCharacters: Int? = nil) -> String {
        let baseSanitized = sanitize(rawText, maxCharacters: nil)
        let filteredLines = baseSanitized
            .components(separatedBy: .newlines)
            .compactMap { filterOCRNoiseLine($0) }

        let joined = filteredLines.joined(separator: "\n")
        let bounded = maxCharacters.map { String(joined.prefix($0)) } ?? joined
        return bounded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extracts lowercased tokens of at least `minimumLength` characters, splitting on
    /// non-alphanumeric boundaries. Used by clipboard relevance and distillation logic.
    static func significantTokens(from text: String, minimumLength: Int = 3) -> Set<String> {
        let words = text.lowercased().components(separatedBy: .alphanumerics.inverted)
        return Set(words.filter { $0.count >= minimumLength })
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

    /// Short technical words and acronyms that are semantically valuable even though generic OCR
    /// filters would treat them as too short or vowel-free.
    private static let preservedTechnicalTokens: Set<String> = [
        "ai", "api", "app", "apps", "ax", "bug", "bugs", "ci", "cmd", "css",
        "dom", "git", "gpu", "html", "http", "id", "ids", "io", "json", "llm",
        "ocr", "pdf", "pr", "prs", "qa", "sql", "ui", "url", "ux", "xpc"
    ]

    private static let commonAcronyms: Set<String> = [
        "AI", "API", "AX", "CI", "CPU", "CSS", "DOM", "GPU", "HTML", "HTTP",
        "ID", "IO", "JSON", "LLM", "OCR", "PDF", "PR", "QA", "SQL", "UI",
        "URL", "UX", "XPC"
    ]

    private static let knownWordSignals = [
        "accept", "app", "autocomplete", "button", "chat", "chrome", "class",
        "code", "context", "cotabby", "document", "email", "error", "field",
        "file", "fix", "function", "github", "google", "issue", "jira", "linear",
        "message", "model", "notion", "pane", "prompt", "pull", "request",
        "safari", "screen", "setting", "slack", "summary", "swift", "task",
        "test", "token", "user", "view", "xcode"
    ]

    private struct OCRTokenAssessment {
        let shouldKeep: Bool
        let isStrongSignal: Bool
    }

    /// Filters a single OCR line with deterministic token scoring, then drops the entire line if
    /// fewer than half its original tokens survived.
    private static func filterOCRNoiseLine(_ line: String) -> String? {
        let tokens = line.components(separatedBy: " ").filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        let assessedTokens = tokens.map { token in
            (token: token, assessment: assessOCRToken(token))
        }
        let kept = assessedTokens
            .filter(\.assessment.shouldKeep)
            .map(\.token)

        // If more than half the tokens were noise, the whole line is probably UI chrome.
        guard kept.count * 2 >= tokens.count else { return nil }
        guard assessedTokens.contains(where: { $0.assessment.shouldKeep && $0.assessment.isStrongSignal }) else {
            return nil
        }

        let result = kept.joined(separator: " ")
        return result.isEmpty ? nil : result
    }

    private static func assessOCRToken(_ token: String) -> OCRTokenAssessment {
        let lowercasedToken = token.lowercased()

        if token.allSatisfy(\.isNumber) {
            return OCRTokenAssessment(shouldKeep: false, isStrongSignal: false)
        }

        if isEmailLikeToken(token) || isFileOrDomainLikeToken(token) {
            return OCRTokenAssessment(shouldKeep: true, isStrongSignal: true)
        }

        if preservedTechnicalTokens.contains(lowercasedToken) || commonAcronyms.contains(token) {
            return OCRTokenAssessment(shouldKeep: true, isStrongSignal: true)
        }

        if isRepeatedGlyphJunk(token) {
            return OCRTokenAssessment(shouldKeep: false, isStrongSignal: false)
        }

        // Non-Latin scripts (CJK, Cyrillic, Greek, Arabic, Hebrew, Thai, ...) and accented Latin
        // (café, Zürich, naïve) carry real context but have no ASCII vowel and never match the
        // English word lists, so the Latin-tuned heuristics below would strip them to nothing and
        // leave non-English users with no visual context at all. Numbers and repeated-glyph junk
        // are already rejected above, so a token carrying genuine non-ASCII letters is real OCR
        // text: keep it as strong signal. (Splitting the Latin tail into its own helper also keeps
        // this function under the cyclomatic-complexity limit.)
        if containsNonASCIILetter(token) {
            return OCRTokenAssessment(shouldKeep: true, isStrongSignal: true)
        }

        return assessLatinToken(token, lowercased: lowercasedToken)
    }

    /// Scores an ASCII-only token. Reached only after `assessOCRToken` has handled numbers, emails,
    /// file/domain tokens, acronyms, repeated-glyph junk, and any token carrying non-ASCII letters.
    private static func assessLatinToken(_ token: String, lowercased lowercasedToken: String) -> OCRTokenAssessment {
        // A token this short can never be repeated-glyph junk (that needs >= 4 scalars), so the
        // earlier ordering relative to that check does not change the outcome.
        if token.count <= 2 {
            let shouldKeep = preservedShortWords.contains(lowercasedToken)
            return OCRTokenAssessment(shouldKeep: shouldKeep, isStrongSignal: false)
        }

        if containsLettersAndNumbers(token) {
            let hasKnownWord = containsKnownWordSignal(token)
            return OCRTokenAssessment(shouldKeep: hasKnownWord, isStrongSignal: hasKnownWord)
        }

        if isLikelyShortMixedCaseNoise(token) {
            return OCRTokenAssessment(shouldKeep: false, isStrongSignal: false)
        }

        let shouldKeep = hasWordSignal(token)
        return OCRTokenAssessment(shouldKeep: shouldKeep, isStrongSignal: shouldKeep)
    }

    /// True when the token carries a letter outside ASCII: CJK, Cyrillic, Greek, Arabic, Hebrew,
    /// Thai, Devanagari, accented Latin, and so on. ASCII letters stay on the Latin-tuned path.
    private static func containsNonASCIILetter(_ token: String) -> Bool {
        token.unicodeScalars.contains { scalar in
            scalar.value > 127 && CharacterSet.letters.contains(scalar)
        }
    }

    private static func isEmailLikeToken(_ token: String) -> Bool {
        let parts = token.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return containsLetter(String(parts[0])) && isFileOrDomainLikeToken(String(parts[1]))
    }

    private static func isFileOrDomainLikeToken(_ token: String) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        return parts.contains { containsLetter(String($0)) }
    }

    private static func containsLettersAndNumbers(_ token: String) -> Bool {
        containsLetter(token) && token.contains(where: \.isNumber)
    }

    private static func containsLetter(_ token: String) -> Bool {
        token.contains(where: \.isLetter)
    }

    private static func containsKnownWordSignal(_ token: String) -> Bool {
        let lowercasedToken = token.lowercased()
        return knownWordSignals.contains { lowercasedToken.contains($0) }
    }

    private static func hasWordSignal(_ token: String) -> Bool {
        guard containsLetter(token) else { return false }
        let lowercasedToken = token.lowercased()
        if containsKnownWordSignal(lowercasedToken) {
            return true
        }

        return lowercasedToken.unicodeScalars.contains { scalar in
            CharacterSet(charactersIn: "aeiouy").contains(scalar)
        }
    }

    private static func isRepeatedGlyphJunk(_ token: String) -> Bool {
        let scalars = token.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        guard scalars.count >= 4 else { return false }

        var frequencies: [UnicodeScalar: Int] = [:]
        for scalar in scalars {
            frequencies[scalar, default: 0] += 1
        }

        let mostCommonCount = frequencies.values.max() ?? 0
        return mostCommonCount * 2 >= scalars.count
    }

    private static func isLikelyShortMixedCaseNoise(_ token: String) -> Bool {
        let letters = token.filter(\.isLetter)
        guard token.count <= 12, letters.count >= 4 else { return false }

        let uppercaseCount = letters.filter(\.isUppercase).count
        let lowercaseCount = letters.filter(\.isLowercase).count
        guard uppercaseCount > 0, lowercaseCount > 0 else { return false }

        if containsKnownWordSignal(token) {
            return false
        }

        // A single leading capital is normal prose ("Safari", "Cotabby"). Multiple capitals in
        // a short token without a known technical word is usually OCR garbage ("gLVWrt", "bDokE").
        let firstCharacterIsUppercase = letters.first?.isUppercase == true
        if firstCharacterIsUppercase && uppercaseCount == 1 {
            return false
        }

        return uppercaseCount >= 2 || !firstCharacterIsUppercase
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
