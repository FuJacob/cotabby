import Foundation

/// File overview:
/// Filters noisy screen-OCR lines before they become autocomplete prompt context.
///
/// Vision OCR over an arbitrary window does not just recover prose. It also recovers UI chrome,
/// progress glyphs, icon ligatures, partially-occluded text, and low-confidence guesses where the
/// recognizer misread letters as digits or emitted the Unicode replacement character. Those
/// fragments are actively harmful for a small local completion model: it can copy a hallucinated
/// token (`qu81ity`, `\u{FFFD}\u{FFFD}\u{FFFD}`, `||==>>`) straight back as the next suggestion.
///
/// This module is a clean-room, pure-Swift hygiene pass. Every guard is an individually-testable
/// static function with a tunable threshold so the policy can be reasoned about and regression-tested
/// in isolation, and so the orchestrating service (`ScreenTextExtractor` / `ScreenshotContextGenerator`)
/// stays free of OCR-noise heuristics. There is no I/O, no logging, and no dependency beyond
/// `Foundation`; the same input always yields the same output.
enum OCRTextHygiene {

    /// A single recognized OCR line paired with the recognizer's confidence for that line.
    ///
    /// Confidence is carried alongside the text because the cheapest, highest-signal filter
    /// (`dropLowConfidence`) needs it. The orchestrating extractor currently discards Vision's
    /// per-candidate confidence; surfacing it into this value type is what lets filter #1 run.
    struct OCRLine: Equatable, Sendable {
        let text: String
        let confidence: Float

        init(text: String, confidence: Float) {
            self.text = text
            self.confidence = confidence
        }
    }

    // MARK: - Allowed character sets

    /// Punctuation that legitimately appears in prose, source code, version strings, URLs, file
    /// paths, and model names. Symbol-density scoring (filter #3) treats these as "expected" so a
    /// line like `gpt-4o-mini (v2.1)` or `arr[i] = foo / bar;` is not punished for being technical.
    ///
    /// The set is intentionally broad: the goal is to flag lines that are *mostly* glyph noise
    /// (box-drawing, arrows, repeated bullets, decorative separators), not lines that simply use a
    /// lot of ordinary punctuation.
    private static let commonPunctuation: Set<Character> = [
        ".", ",", "!", "?", ";", ":", "'", "\"", "(", ")", "[", "]", "{", "}",
        "-", "/", "&", "%", "$", "#", "@", "*", "+", "=", "<", ">", "`", "~",
        "_", "|", "\\"
    ]

    // MARK: - Filter 1: low-confidence drop

    /// Drops lines the recognizer was not confident about.
    ///
    /// Low-confidence OCR lines are the single largest source of garbage tokens, so this runs
    /// first and cheaply. Vision reports confidence in `0...1`; the default `0.4` keeps ordinary
    /// recognized text while discarding the recognizer's weakest guesses.
    static func dropLowConfidence(_ lines: [OCRLine], threshold: Float = 0.4) -> [OCRLine] {
        lines.filter { $0.confidence >= threshold }
    }

    // MARK: - Filter 2: replacement-character drop

    /// Drops any line containing U+FFFD, the Unicode replacement character.
    ///
    /// A `\u{FFFD}` in OCR output means the recognizer produced a glyph it could not map to a real
    /// character. Such a line is by definition corrupted, and the replacement glyph would otherwise
    /// survive sanitization as visible noise in the prompt.
    static func dropReplacementCharacter(_ lines: [OCRLine]) -> [OCRLine] {
        lines.filter { !$0.text.contains("\u{FFFD}") }
    }

    // MARK: - Filter 3: symbol-density drop

    /// Drops lines that are mostly symbol noise rather than text.
    ///
    /// A line is dropped when the fraction of characters that are *neither* alphanumeric, nor a
    /// space, nor common punctuation exceeds `threshold` (default `0.2`). This targets box-drawing,
    /// arrow runs, decorative separators, and icon ligatures while leaving prose, code, version
    /// numbers, and model names intact, because their punctuation is in the allowed set.
    ///
    /// Empty / whitespace-only lines carry no symbol noise, so they are kept here and removed by the
    /// later word-character guard or by trimming in `clean`.
    static func dropHighSymbolDensity(_ lines: [OCRLine], threshold: Double = 0.2) -> [OCRLine] {
        lines.filter { !isHighSymbolDensity($0.text, threshold: threshold) }
    }

    private static func isHighSymbolDensity(_ text: String, threshold: Double) -> Bool {
        let characters = Array(text)
        guard !characters.isEmpty else { return false }

        let symbolCount = characters.reduce(into: 0) { count, character in
            if !isAllowedDensityCharacter(character) {
                count += 1
            }
        }

        return Double(symbolCount) / Double(characters.count) > threshold
    }

    /// A character is "expected" for density purposes when it is alphanumeric (any script), a
    /// space, or in the common-punctuation set. Everything else counts toward symbol noise.
    private static func isAllowedDensityCharacter(_ character: Character) -> Bool {
        if character == " " || commonPunctuation.contains(character) {
            return true
        }
        return character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    // MARK: - Filter 4: digit-substitution drop

    /// Drops lines containing a token that looks like OCR misread letters as digits.
    ///
    /// The signature this targets is a digit that sits *inside* a lowercase word: a lowercase
    /// letter appears somewhere before the digit in the same token, and some letter appears
    /// somewhere after it (`qu81ity`, `h3llo`). That pattern is almost never real text but is a
    /// common OCR failure where `a/o`->`8`, `e`->`3`, `i/l`->`1`, and so on.
    ///
    /// The "lowercase before" + "letter after" pairing is deliberately narrow so genuine tokens
    /// survive:
    /// - trailing digits (`utf8`, `v2`): no letter after the digit.
    /// - leading digits (`3D`, `5070`): no letter before the digit at all.
    /// - hyphenated counts (`20-core`): the digits have no lowercase letter before them.
    /// - ALL-CAPS identifiers (`RTX5070`, `N1X`): the letters before the digit are uppercase, so
    ///   the "lowercase before" condition is never met (uppercase model/product codes are real).
    static func dropDigitSubstitution(_ lines: [OCRLine]) -> [OCRLine] {
        lines.filter { line in
            !tokens(in: line.text).contains(where: tokenHasDigitSubstitution)
        }
    }

    /// True when some digit in the token has a lowercase letter before it and any letter after it.
    private static func tokenHasDigitSubstitution(_ token: String) -> Bool {
        let characters = Array(token)
        guard characters.contains(where: { $0.isNumber }) else { return false }

        for (index, character) in characters.enumerated() where character.isNumber {
            let hasLowercaseBefore = characters[..<index].contains { $0.isLowercase }
            guard hasLowercaseBefore else { continue }

            let hasLetterAfter = characters[(index + 1)...].contains { $0.isLetter }
            if hasLetterAfter {
                return true
            }
        }

        return false
    }

    // MARK: - Filter 5: word-character-ratio drop

    /// Drops lines whose visible content is mostly non-word characters.
    ///
    /// A line is dropped when the ratio of alphanumeric characters to non-space characters falls
    /// below `threshold` (default `0.5`). Where symbol-density (#3) catches dense glyph runs, this
    /// catches lines that are technically "allowed" punctuation yet carry almost no letters, such
    /// as `--- :: --- ::` or a row of dotted leaders. Whitespace is excluded from the denominator
    /// so indentation does not skew the ratio; whitespace-only lines have no word characters and
    /// are dropped.
    static func dropLowWordCharacterRatio(_ lines: [OCRLine], threshold: Double = 0.5) -> [OCRLine] {
        lines.filter { wordCharacterRatio($0.text) >= threshold }
    }

    private static func wordCharacterRatio(_ text: String) -> Double {
        var nonSpaceCount = 0
        var wordCount = 0
        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            nonSpaceCount += 1
            if CharacterSet.alphanumerics.contains(scalar) {
                wordCount += 1
            }
        }

        guard nonSpaceCount > 0 else { return 0 }
        return Double(wordCount) / Double(nonSpaceCount)
    }

    // MARK: - Filter 6: field-text stripping

    /// Removes OCR lines that merely echo what the user already has in the focused field.
    ///
    /// The screenshot region overlaps the focused input, so OCR routinely re-reads the user's own
    /// text. Feeding that back as "context" is redundant at best and biases the model toward
    /// repeating it. A line is dropped when its normalized form (lowercased, whitespace-collapsed)
    /// is a substring of the normalized field text.
    ///
    /// `minMatch` (default `4`) guards against stripping short coincidental words: a one- or
    /// two-character OCR line like `to` would otherwise be a substring of almost any field text.
    /// Only normalized lines of at least `minMatch` characters are eligible for stripping.
    static func strip(lines: [OCRLine], fieldText: String, minMatch: Int = 4) -> [OCRLine] {
        let normalizedField = normalize(fieldText)
        guard !normalizedField.isEmpty else { return lines }

        return lines.filter { line in
            let normalizedLine = normalize(line.text)
            guard normalizedLine.count >= minMatch else { return true }
            return !normalizedField.contains(normalizedLine)
        }
    }

    /// Lowercases and collapses all whitespace runs to single spaces, trimming the ends.
    ///
    /// Both the field text and each OCR line pass through this so that case differences and OCR
    /// spacing artifacts (`Hello   World` vs `hello world`) still match during stripping.
    private static func normalize(_ text: String) -> String {
        let lowercased = text.lowercased()
        let collapsed = lowercased.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Top-level pipeline

    /// Runs every hygiene guard in order, bounds the result, and returns the joined cleaned text.
    ///
    /// Ordering is chosen so cheap, high-signal drops run before more expensive token scans, and so
    /// that field-text stripping happens last on lines that already survived noise filtering:
    /// 1. low-confidence (cheapest, removes the most garbage)
    /// 2. replacement-character (corrupted lines)
    /// 3. symbol-density (glyph-noise lines)
    /// 4. digit-substitution (per-token OCR misreads)
    /// 5. word-character-ratio (low-letter punctuation lines)
    /// 6. field-text stripping (echoes of the user's own text)
    ///
    /// The surviving lines are trimmed, empties dropped, then bounded to at most `maxLines`
    /// (default `40`) and `maxChars` (default `2000`) so a pathological screen cannot flood the
    /// prompt. The character bound is applied to the final joined string.
    static func clean(
        lines: [OCRLine],
        fieldText: String,
        maxLines: Int = 40,
        maxChars: Int = 2000
    ) -> String {
        var filtered = dropLowConfidence(lines)
        filtered = dropReplacementCharacter(filtered)
        filtered = dropHighSymbolDensity(filtered)
        filtered = dropDigitSubstitution(filtered)
        filtered = dropLowWordCharacterRatio(filtered)
        filtered = strip(lines: filtered, fieldText: fieldText)

        let cleanedLines = filtered
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(max(0, maxLines))

        let joined = cleanedLines.joined(separator: "\n")
        return String(joined.prefix(max(0, maxChars)))
    }

    // MARK: - Tokenization

    /// Splits a line into whitespace-delimited tokens.
    ///
    /// Whitespace is the boundary because the digit-substitution guard reasons about a digit's
    /// position *within a single visual token*. Splitting on punctuation would, for example, break
    /// `20-core` into `20` and `core` and lose the structure the guard depends on.
    private static func tokens(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}
