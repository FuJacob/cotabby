import XCTest
@testable import Cotabby

/// Pure-function tests for the screen-OCR text-hygiene pass.
///
/// Each filter is exercised in isolation, then `clean` is checked end-to-end. The digit-substitution
/// guard gets an explicit preserve/drop matrix because its correctness hinges on a narrow "lowercase
/// before, letter after" rule that must keep real technical tokens (`utf8`, `RTX5070`, `20-core`)
/// while dropping OCR misreads (`qu81ity`, `h3llo`).
final class OCRTextHygieneTests: XCTestCase {

    private typealias Line = OCRTextHygiene.OCRLine

    private func line(_ text: String, _ confidence: Float = 1.0) -> Line {
        Line(text: text, confidence: confidence)
    }

    private func texts(_ lines: [Line]) -> [String] {
        lines.map(\.text)
    }

    // MARK: - Filter 1: low-confidence drop

    func test_dropLowConfidence_dropsBelowDefaultThreshold() {
        let input = [line("keep me", 0.41), line("drop me", 0.39), line("edge", 0.4)]
        let result = OCRTextHygiene.dropLowConfidence(input)
        XCTAssertEqual(texts(result), ["keep me", "edge"])
    }

    func test_dropLowConfidence_honorsCustomThreshold() {
        let input = [line("a", 0.7), line("b", 0.6)]
        let result = OCRTextHygiene.dropLowConfidence(input, threshold: 0.65)
        XCTAssertEqual(texts(result), ["a"])
    }

    // MARK: - Filter 2: replacement-character drop

    func test_dropReplacementCharacter_dropsLinesWithReplacementGlyph() {
        let input = [line("clean line"), line("corru\u{FFFD}pted"), line("also clean")]
        let result = OCRTextHygiene.dropReplacementCharacter(input)
        XCTAssertEqual(texts(result), ["clean line", "also clean"])
    }

    // MARK: - Filter 3: symbol-density drop

    func test_dropHighSymbolDensity_dropsBoxDrawingNoise() {
        let input = [line("\u{250C}\u{2500}\u{2500}\u{2500}\u{2510}")]
        let result = OCRTextHygiene.dropHighSymbolDensity(input)
        XCTAssertTrue(result.isEmpty)
    }

    func test_dropHighSymbolDensity_keepsProse() {
        let input = [line("Hello, world! This is fine.")]
        let result = OCRTextHygiene.dropHighSymbolDensity(input)
        XCTAssertEqual(texts(result), ["Hello, world! This is fine."])
    }

    func test_dropHighSymbolDensity_keepsCodeAndVersionAndModelNames() {
        let input = [
            line("arr[i] = foo / bar; // ok"),
            line("gpt-4o-mini (v2.1)"),
            line("path/to/file.swift")
        ]
        let result = OCRTextHygiene.dropHighSymbolDensity(input)
        XCTAssertEqual(texts(result), texts(input))
    }

    func test_dropHighSymbolDensity_dropsNonAsciiGlyphRun() {
        // Em-dashes and bullets are not in the allowed punctuation set and should read as noise.
        let input = [line("\u{2014}\u{2014}\u{2022}\u{2022}\u{2014}\u{2014}")]
        let result = OCRTextHygiene.dropHighSymbolDensity(input)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Filter 4: digit-substitution drop (preserve / drop matrix)

    func test_dropDigitSubstitution_dropsMisreadTokens() {
        for token in ["qu81ity", "h3llo"] {
            let result = OCRTextHygiene.dropDigitSubstitution([line(token)])
            XCTAssertTrue(result.isEmpty, "expected \(token) to be dropped")
        }
    }

    func test_dropDigitSubstitution_preservesRealTokens() {
        for token in ["utf8", "v2", "3D", "5070", "20-core", "RTX5070", "N1X"] {
            let result = OCRTextHygiene.dropDigitSubstitution([line(token)])
            XCTAssertEqual(texts(result), [token], "expected \(token) to be preserved")
        }
    }

    func test_dropDigitSubstitution_dropsLineWhenAnyTokenMatches() {
        let input = [line("the qu81ity is poor"), line("clean utf8 line")]
        let result = OCRTextHygiene.dropDigitSubstitution(input)
        XCTAssertEqual(texts(result), ["clean utf8 line"])
    }

    func test_dropDigitSubstitution_preservesMixedRealNumbers() {
        // A sentence with ordinary numbers and trailing/leading digits must survive intact.
        let input = [line("use v2 on the 5070 with utf8 and 20-core")]
        let result = OCRTextHygiene.dropDigitSubstitution(input)
        XCTAssertEqual(texts(result), texts(input))
    }

    // MARK: - Filter 5: word-character-ratio drop

    func test_dropLowWordCharacterRatio_dropsPunctuationHeavyLine() {
        let input = [line("--- :: --- :: ---")]
        let result = OCRTextHygiene.dropLowWordCharacterRatio(input)
        XCTAssertTrue(result.isEmpty)
    }

    func test_dropLowWordCharacterRatio_keepsNormalSentence() {
        let input = [line("This sentence has plenty of letters.")]
        let result = OCRTextHygiene.dropLowWordCharacterRatio(input)
        XCTAssertEqual(texts(result), texts(input))
    }

    func test_dropLowWordCharacterRatio_dropsWhitespaceOnlyLine() {
        let input = [line("    ")]
        let result = OCRTextHygiene.dropLowWordCharacterRatio(input)
        XCTAssertTrue(result.isEmpty)
    }

    func test_dropLowWordCharacterRatio_ignoresLeadingWhitespaceInRatio() {
        // Indentation should not push an otherwise wordy line below the ratio threshold.
        let input = [line("        indented code here")]
        let result = OCRTextHygiene.dropLowWordCharacterRatio(input)
        XCTAssertEqual(texts(result), texts(input))
    }

    // MARK: - Filter 6: field-text stripping

    func test_strip_dropsExactEcho() {
        let input = [line("hello world"), line("unrelated context")]
        let result = OCRTextHygiene.strip(lines: input, fieldText: "hello world")
        XCTAssertEqual(texts(result), ["unrelated context"])
    }

    func test_strip_dropsCaseDifferentEcho() {
        let input = [line("Hello World")]
        let result = OCRTextHygiene.strip(lines: input, fieldText: "hello world")
        XCTAssertTrue(result.isEmpty)
    }

    func test_strip_dropsWhitespaceDifferentEcho() {
        let input = [line("Hello    World")]
        let result = OCRTextHygiene.strip(lines: input, fieldText: "the hello world here")
        XCTAssertTrue(result.isEmpty)
    }

    func test_strip_keepsTooShortCoincidence() {
        // "to" is a substring of the field text but shorter than minMatch, so it must NOT be stripped.
        let input = [line("to")]
        let result = OCRTextHygiene.strip(lines: input, fieldText: "this is something to read")
        XCTAssertEqual(texts(result), ["to"])
    }

    func test_strip_keepsNonSubstringLine() {
        let input = [line("completely different")]
        let result = OCRTextHygiene.strip(lines: input, fieldText: "hello world")
        XCTAssertEqual(texts(result), ["completely different"])
    }

    func test_strip_honorsCustomMinMatch() {
        // With a higher minMatch, a medium-length echo is kept because it is below the bar.
        let input = [line("hello")]
        let result = OCRTextHygiene.strip(lines: input, fieldText: "hello there", minMatch: 8)
        XCTAssertEqual(texts(result), ["hello"])
    }

    func test_strip_withEmptyFieldText_keepsEverything() {
        let input = [line("anything"), line("else")]
        let result = OCRTextHygiene.strip(lines: input, fieldText: "")
        XCTAssertEqual(texts(result), ["anything", "else"])
    }

    // MARK: - Top-level clean

    func test_clean_runsAllFiltersAndJoins() {
        let input = [
            line("This is a genuine line of prose."),
            line("low confidence noise", 0.1),
            line("corru\u{FFFD}pted glyph"),
            line("\u{250C}\u{2500}\u{2500}\u{2500}\u{2510}"),
            line("the qu81ity is poor"),
            line("--- :: --- :: ---"),
            line("echo of field"),
            line("Another useful sentence with words.")
        ]

        let result = OCRTextHygiene.clean(lines: input, fieldText: "echo of field")
        let resultLines = result.components(separatedBy: "\n")

        XCTAssertEqual(
            resultLines,
            ["This is a genuine line of prose.", "Another useful sentence with words."]
        )
    }

    func test_clean_trimsAndDropsEmptyLines() {
        let input = [line("   spaced out   "), line("   ")]
        let result = OCRTextHygiene.clean(lines: input, fieldText: "")
        XCTAssertEqual(result, "spaced out")
    }

    func test_clean_boundsMaxLines() {
        let input = (0..<60).map { line("line number \($0) has words") }
        let result = OCRTextHygiene.clean(lines: input, fieldText: "", maxLines: 5)
        XCTAssertEqual(result.components(separatedBy: "\n").count, 5)
    }

    func test_clean_boundsMaxChars() {
        let input = [line(String(repeating: "abcde ", count: 200))]
        let result = OCRTextHygiene.clean(lines: input, fieldText: "", maxChars: 50)
        XCTAssertEqual(result.count, 50)
    }

    func test_clean_withNoSurvivingLines_returnsEmptyString() {
        let input = [line("garbage", 0.1), line("\u{250C}\u{2500}\u{2510}")]
        let result = OCRTextHygiene.clean(lines: input, fieldText: "")
        XCTAssertTrue(result.isEmpty)
    }

    func test_clean_preservesTechnicalContent() {
        // A realistic mix of code-ish lines should pass through clean untouched. Tokens are kept to
        // the spec's guaranteed-pass shapes (trailing digits, version strings, ALL-CAPS codes);
        // a lowercase-internal-digit token like "gpt-4o-mini" is intentionally NOT asserted here
        // because rule #4 cannot distinguish it from an OCR misread.
        let input = [
            line("func render(_ text: String) -> View {"),
            line("config uses utf8 with v2.1"),
            line("install on RTX5070 and N1X")
        ]
        let result = OCRTextHygiene.clean(lines: input, fieldText: "")
        XCTAssertEqual(result.components(separatedBy: "\n"), texts(input))
    }
}
