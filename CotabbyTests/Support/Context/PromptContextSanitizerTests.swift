import XCTest
@testable import Cotabby

/// Pure-function tests for the clipboard/OCR prompt-context sanitizer. `sanitize` reduces text to
/// letters, digits, whitespace, `@`, and `.`; `sanitizeOCR` additionally scores each token and drops
/// lines that are mostly OCR noise. Outputs are asserted exactly because whatever survives is
/// copied verbatim into the prompt.
final class PromptContextSanitizerTests: XCTestCase {

    private func assertSanitizedOCR(
        _ cases: [(input: String, expected: String)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for testCase in cases {
            XCTAssertEqual(
                PromptContextSanitizer.sanitizeOCR(testCase.input),
                testCase.expected,
                "input \(testCase.input.debugDescription)",
                file: file,
                line: line
            )
        }
    }

    // MARK: - sanitize

    /// Disallowed scalars become spaces (preserving word boundaries: `raw-output` -> `raw output`),
    /// ANSI escapes are removed whole, whitespace runs collapse, and blank lines disappear.
    func test_sanitize_normalizesToPromptSafeText() {
        let cases: [(input: String, expected: String)] = [
            ("raw-output", "raw output"),
            ("hello    world", "hello world"),
            ("a\t\tb", "a b"),
            ("first\n   \n\nsecond", "first\nsecond"),
            ("one\r\ntwo", "one\ntwo"),
            ("Hello world 123 user@host.com", "Hello world 123 user@host.com"),
            ("\u{001B}[31mERROR\u{001B}[0m something broke", "ERROR something broke"),
            ("\u{001B}[32mHello\u{001B}[0m world", "Hello world"),
            ("   \n  \n  ", ""),
            ("", "")
        ]
        for testCase in cases {
            XCTAssertEqual(
                PromptContextSanitizer.sanitize(testCase.input),
                testCase.expected,
                "input \(testCase.input.debugDescription)"
            )
        }
    }

    /// The bound applies after normalization, and a cut that lands on a space is trimmed.
    func test_sanitize_boundsToMaxCharacters() {
        XCTAssertEqual(PromptContextSanitizer.sanitize("abcdefghij", maxCharacters: 5), "abcde")
        XCTAssertEqual(PromptContextSanitizer.sanitize("hello", maxCharacters: 5), "hello")
        XCTAssertEqual(PromptContextSanitizer.sanitize("hello   world", maxCharacters: 6), "hello")
    }

    // MARK: - sanitizeOCR token scoring

    /// Standalone numbers, unlisted 1-2 letter tokens, repeated glyphs, letterless dotted numbers,
    /// and lowercase-led mixed-case blobs are noise; the rest of the line survives when at least
    /// half its tokens do.
    func test_sanitizeOCR_dropsNoiseTokensFromOtherwiseRealLines() {
        assertSanitizedOCR([
            ("hello 50 world 424", "hello world"),        // exactly half survive: kept
            ("I like if x", "I like if"),                 // "I"/"if" are preserved short words
            ("meeting notes aaaa", "meeting notes"),
            ("meeting notes 12.34", "meeting notes"),
            ("meeting notes abeW", "meeting notes"),
            ("meeting notes swift5 abc123", "meeting notes swift5") // letters+digits need a known word
        ])
    }

    /// Short technical words and uppercase acronyms are strong signal even without vowels.
    func test_sanitizeOCR_keepsTechnicalTokensAcronymsFilesAndEmails() {
        let technical = "Cotabby CoHamster PR API context needs GeneralPaneView.swift "
            + "normalizedBundleIdentifier jane@example.com"
        assertSanitizedOCR([
            (technical, technical),
            ("CPU ui ok", "CPU ui")
        ])
    }

    // MARK: - sanitizeOCR line filtering

    /// A line is dropped whole when more than half its tokens are noise, or when every survivor is
    /// a weak short word (UI chrome like "we go to it").
    func test_sanitizeOCR_dropsNoiseDominatedAndWeakOnlyLines() {
        assertSanitizedOCR([
            ("50 x 99 hello", ""),
            ("50 424 102 99", ""),
            ("gLVWrt 54tbdbDX bDokE User", ""),
            ("we go to it", ""),
            ("*** ---", ""),   // sanitizes to one empty line: no tokens, no crash
            ("", "")
        ])
    }

    func test_sanitizeOCR_dropsGarbageLineButKeepsRealLine() {
        let input = """
        gLVWrt bDokE 54tbdbDX
        Visible task update Screen Recording copy for Cotabby
        """
        XCTAssertEqual(
            PromptContextSanitizer.sanitizeOCR(input),
            "Visible task update Screen Recording copy for Cotabby"
        )
    }

    /// CJK, Cyrillic, and accented Latin carry real context but have no ASCII vowel and never match
    /// the English word lists; they must survive so non-English users keep visual context. The
    /// allowance must not become a backdoor for ASCII garbage (or unlisted short Latin words like
    /// "la") on the same line.
    func test_sanitizeOCR_preservesNonLatinScriptsWithoutAdmittingAsciiNoise() {
        let input = """
        会議の議題を確認してください
        Привет команда смотрите задачу
        Préparez la réunion à Zürich
        """
        XCTAssertEqual(
            PromptContextSanitizer.sanitizeOCR(input),
            "会議の議題を確認してください\nПривет команда смотрите задачу\nPréparez réunion à Zürich"
        )
        XCTAssertEqual(PromptContextSanitizer.sanitizeOCR("東京 gLVWrt オフィス 54tbdbDX"), "東京 オフィス")
    }

    /// The OCR bound applies to the filtered, joined text, then trims a trailing cut space.
    func test_sanitizeOCR_boundsToMaxCharacters() {
        XCTAssertEqual(
            PromptContextSanitizer.sanitizeOCR("alpha beta gamma delta epsilon", maxCharacters: 10),
            "alpha beta"
        )
        XCTAssertEqual(
            PromptContextSanitizer.sanitizeOCR("50 424\nalpha beta gamma", maxCharacters: 11),
            "alpha beta"
        )
    }

    // MARK: - significantTokens

    /// Lowercased tokens split on any non-alphanumeric boundary, deduplicated, and length-filtered.
    func test_significantTokens_splitsLowercasesAndFiltersByLength() {
        XCTAssertEqual(
            PromptContextSanitizer.significantTokens(from: "Hello, hello WORLD! swift-ui an"),
            ["hello", "world", "swift"]
        )
        XCTAssertEqual(
            PromptContextSanitizer.significantTokens(from: "an ox ran far", minimumLength: 2),
            ["an", "ox", "ran", "far"]
        )
        XCTAssertEqual(PromptContextSanitizer.significantTokens(from: "--- ,,,"), [])
    }

    // MARK: - containsAlphanumericSignal

    func test_containsAlphanumericSignal() {
        let cases: [(text: String, expected: Bool)] = [
            ("---a---", true),
            ("--- 7", true),
            ("東", true),
            ("--- ---", false),
            ("", false)
        ]
        for testCase in cases {
            XCTAssertEqual(
                PromptContextSanitizer.containsAlphanumericSignal(testCase.text),
                testCase.expected,
                "text \(testCase.text.debugDescription)"
            )
        }
    }
}
