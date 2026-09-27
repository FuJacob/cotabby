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

    /// Density counts characters that are neither alphanumeric (any script), a space, nor common
    /// punctuation, and drops the line only when that fraction strictly exceeds 0.2.
    func test_dropHighSymbolDensity_keepsTextAndDropsGlyphNoise() {
        let cases: [(text: String, kept: Bool)] = [
            ("Hello, world! This is fine.", true),
            ("arr[i] = foo / bar; // ok", true),
            ("gpt-4o-mini (v2.1)", true),
            ("path/to/file.swift", true),
            ("日本語のテキスト", true),                          // non-Latin letters are word characters
            ("", true),                                          // nothing to score; later guards drop it
            ("abcd\u{2192}", true),                             // exactly 1/5 = 0.2 is not "over"
            ("abc\u{2192}", false),                             // 1/4 = 0.25
            ("\u{250C}\u{2500}\u{2500}\u{2500}\u{2510}", false), // box drawing
            ("\u{2014}\u{2014}\u{2022}\u{2022}\u{2014}\u{2014}", false) // em-dashes and bullets
        ]
        for testCase in cases {
            let result = OCRTextHygiene.dropHighSymbolDensity([line(testCase.text)])
            XCTAssertEqual(result.isEmpty, !testCase.kept, "text \(testCase.text.debugDescription)")
        }
    }

    func test_dropHighSymbolDensity_honorsCustomThreshold() {
        // 1/4 symbols passes a 0.3 ceiling that the default 0.2 would reject.
        let result = OCRTextHygiene.dropHighSymbolDensity([line("abc\u{2192}")], threshold: 0.3)
        XCTAssertEqual(texts(result), ["abc\u{2192}"])
    }

    // MARK: - Filter 4: digit-substitution drop (preserve / drop matrix)

    func test_dropDigitSubstitution_dropsMisreadTokens() {
        for token in ["qu81ity", "h3llo", "x2y"] {
            let result = OCRTextHygiene.dropDigitSubstitution([line(token)])
            XCTAssertTrue(result.isEmpty, "expected \(token) to be dropped")
        }
    }

    func test_dropDigitSubstitution_preservesRealTokens() {
        for token in ["utf8", "v2", "3D", "5070", "20-core", "RTX5070", "N1X", "A1b"] {
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

    /// Keeps lines whose alphanumeric share of non-space characters is at least 0.5. Whitespace is
    /// excluded from the denominator, so indentation cannot sink a wordy line, and whitespace-only
    /// lines score zero.
    func test_dropLowWordCharacterRatio_matrix() {
        let cases: [(text: String, kept: Bool)] = [
            ("This sentence has plenty of letters.", true),
            ("        indented code here", true),
            ("ab--", true),               // exactly 2/4 = 0.5 meets the threshold
            ("ab---", false),             // 2/5 = 0.4
            ("--- :: --- :: ---", false),
            ("    ", false)
        ]
        for testCase in cases {
            let result = OCRTextHygiene.dropLowWordCharacterRatio([line(testCase.text)])
            XCTAssertEqual(result.isEmpty, !testCase.kept, "text \(testCase.text.debugDescription)")
        }
    }

    // MARK: - Filter 6: field-text stripping

    /// A line is stripped when its lowercased, whitespace-collapsed form is a substring of the
    /// equally normalized field text and is at least `minMatch` (default 4) characters long, so
    /// short coincidences like "to" survive.
    func test_strip_matrix() {
        let cases: [(line: String, field: String, kept: Bool)] = [
            ("hello world", "hello world", false),
            ("Hello World", "hello world", false),
            ("Hello    World", "the hello   world here", false),
            ("read", "something to read", false),  // exactly minMatch characters
            ("rea", "something to read", true),    // one below minMatch
            ("to", "this is something to read", true),
            ("completely different", "hello world", true),
            ("anything", "", true),                // no field text: nothing to echo
            ("anything", "  \n ", true)            // whitespace-only field normalizes to empty
        ]
        for testCase in cases {
            let result = OCRTextHygiene.strip(lines: [line(testCase.line)], fieldText: testCase.field)
            XCTAssertEqual(
                result.isEmpty,
                !testCase.kept,
                "line \(testCase.line.debugDescription) field \(testCase.field.debugDescription)"
            )
        }
    }

    func test_strip_honorsCustomMinMatch() {
        // With a higher minMatch, a medium-length echo is kept because it is below the bar.
        let result = OCRTextHygiene.strip(lines: [line("hello")], fieldText: "hello there", minMatch: 8)
        XCTAssertEqual(texts(result), ["hello"])
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

    /// Line bounding keeps the FIRST lines in reading order; the default cap is 40.
    func test_clean_boundsMaxLinesKeepingEarliest() {
        let input = (0..<60).map { line("line number \($0) has words") }
        XCTAssertEqual(
            OCRTextHygiene.clean(lines: input, fieldText: "", maxLines: 2),
            "line number 0 has words\nline number 1 has words"
        )
        XCTAssertEqual(OCRTextHygiene.clean(lines: input, fieldText: "").components(separatedBy: "\n").count, 40)
        XCTAssertEqual(OCRTextHygiene.clean(lines: input, fieldText: "", maxLines: 0), "")
    }

    /// The character cap applies to the final joined string, newline separators included.
    func test_clean_boundsMaxCharsOnJoinedText() {
        let input = [line("first line"), line("second line")]
        XCTAssertEqual(OCRTextHygiene.clean(lines: input, fieldText: "", maxChars: 13), "first line\nse")
        XCTAssertEqual(OCRTextHygiene.clean(lines: input, fieldText: "", maxChars: -1), "")
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
