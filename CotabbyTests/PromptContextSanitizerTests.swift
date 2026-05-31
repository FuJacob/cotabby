import XCTest
@testable import Cotabby

final class PromptContextSanitizerTests: XCTestCase {

    // MARK: - sanitize

    func test_sanitize_stripsANSIEscapeSequences() {
        let input = "\u{001B}[31mERROR\u{001B}[0m something broke"
        let result = PromptContextSanitizer.sanitize(input)
        XCTAssertFalse(result.contains("\u{001B}"))
        XCTAssertTrue(result.contains("ERROR"))
        XCTAssertTrue(result.contains("something broke"))
    }

    func test_sanitize_replacesDisallowedUnicodeWithSpacesPreservingWordBoundaries() {
        let result = PromptContextSanitizer.sanitize("raw-output")
        XCTAssertEqual(result, "raw output")
    }

    func test_sanitize_collapsesRepeatedWhitespaceIntoSingleSpaces() {
        let result = PromptContextSanitizer.sanitize("hello    world")
        XCTAssertEqual(result, "hello world")
    }

    func test_sanitize_filtersEmptyAndWhitespaceOnlyLines() {
        let input = "first\n   \n\nsecond"
        let result = PromptContextSanitizer.sanitize(input)
        XCTAssertEqual(result, "first\nsecond")
    }

    func test_sanitize_respectsMaxCharactersLimit() {
        let input = "abcdefghij"
        let result = PromptContextSanitizer.sanitize(input, maxCharacters: 5)
        XCTAssertEqual(result, "abcde")
    }

    func test_sanitize_returnsFullInputWhenMaxCharactersEqualsLength() {
        let input = "hello"
        let result = PromptContextSanitizer.sanitize(input, maxCharacters: 5)
        XCTAssertEqual(result, "hello")
    }

    func test_sanitize_returnsEmptyStringForWhitespaceOnlyInput() {
        XCTAssertEqual(PromptContextSanitizer.sanitize("   \n  \n  "), "")
    }

    func test_sanitize_returnsEmptyStringForEmptyInput() {
        XCTAssertEqual(PromptContextSanitizer.sanitize(""), "")
    }

    func test_sanitize_preservesAllowedCharacters() {
        let input = "Hello world 123 user@host.com"
        let result = PromptContextSanitizer.sanitize(input)
        XCTAssertEqual(result, input)
    }

    func test_sanitize_handlesANSIMixedWithRealText() {
        let input = "\u{001B}[32mHello\u{001B}[0m world"
        let result = PromptContextSanitizer.sanitize(input)
        XCTAssertEqual(result, "Hello world")
    }

    // MARK: - sanitizeOCR

    func test_sanitizeOCR_dropsStandaloneNumbers() {
        let input = "hello 50 world 424"
        let result = PromptContextSanitizer.sanitizeOCR(input)
        XCTAssertFalse(result.contains("50"))
        XCTAssertFalse(result.contains("424"))
        XCTAssertTrue(result.contains("hello"))
        XCTAssertTrue(result.contains("world"))
    }

    func test_sanitizeOCR_dropsShortNoiseTokensButKeepsPreservedWords() {
        // "I" and "if" are in the preserved set; "x" is not
        let input = "I like if x"
        let result = PromptContextSanitizer.sanitizeOCR(input)
        XCTAssertTrue(result.contains("I"))
        XCTAssertTrue(result.contains("if"))
        XCTAssertTrue(result.contains("like"))
        XCTAssertFalse(result.contains(" x"))
    }

    func test_sanitizeOCR_dropsLineWhenMajorityTokensAreNoise() {
        // 3 of 4 tokens are noise (>50%): "50", "x", "99" — only "hello" survives
        let input = "50 x 99 hello"
        let result = PromptContextSanitizer.sanitizeOCR(input)
        XCTAssertEqual(result, "")
    }

    func test_sanitizeOCR_keepsLineWhenHalfOrMoreTokensSurvive() {
        // 2 of 4 tokens survive (exactly 50%): kept.count * 2 >= tokens.count
        let input = "hello world 50 99"
        let result = PromptContextSanitizer.sanitizeOCR(input)
        XCTAssertTrue(result.contains("hello"))
        XCTAssertTrue(result.contains("world"))
    }

    func test_sanitizeOCR_respectsMaxCharacters() {
        let input = "alpha beta gamma delta epsilon"
        let result = PromptContextSanitizer.sanitizeOCR(input, maxCharacters: 10)
        XCTAssertLessThanOrEqual(result.count, 10)
    }

    func test_sanitizeOCR_returnsEmptyForAllNoiseInput() {
        let input = "50 424 102 99"
        let result = PromptContextSanitizer.sanitizeOCR(input)
        XCTAssertEqual(result, "")
    }

    func test_sanitizeOCR_dropsRandomMixedCaseAndAlphanumericGarbage() {
        let input = """
        gLVWrt bDokE 54tbdbDX
        Visible task update Screen Recording copy for Cotabby
        """

        let result = PromptContextSanitizer.sanitizeOCR(input)

        XCTAssertFalse(result.contains("gLVWrt"))
        XCTAssertFalse(result.contains("bDokE"))
        XCTAssertFalse(result.contains("54tbdbDX"))
        XCTAssertTrue(result.contains("Visible task update Screen Recording copy for Cotabby"))
    }

    func test_sanitizeOCR_preservesUsefulTechnicalAndUserContext() {
        let input = """
        Cotabby PR API context needs GeneralPaneView.swift normalizedBundleIdentifier jane@example.com
        """

        let result = PromptContextSanitizer.sanitizeOCR(input)

        XCTAssertTrue(result.contains("Cotabby"))
        XCTAssertTrue(result.contains("PR"))
        XCTAssertTrue(result.contains("API"))
        XCTAssertTrue(result.contains("GeneralPaneView.swift"))
        XCTAssertTrue(result.contains("normalizedBundleIdentifier"))
        XCTAssertTrue(result.contains("jane@example.com"))
    }

    func test_sanitizeOCR_dropsLineWhereMostTokensAreOCRNoise() {
        let input = "gLVWrt 54tbdbDX bDokE User"
        let result = PromptContextSanitizer.sanitizeOCR(input)
        XCTAssertEqual(result, "")
    }

    // MARK: - containsAlphanumericSignal

    func test_containsAlphanumericSignal_returnsTrueForMixedInput() {
        XCTAssertTrue(PromptContextSanitizer.containsAlphanumericSignal("---a---"))
    }

    func test_containsAlphanumericSignal_returnsFalseForPureSymbols() {
        XCTAssertFalse(PromptContextSanitizer.containsAlphanumericSignal("--- ---"))
    }

    func test_containsAlphanumericSignal_returnsFalseForEmptyString() {
        XCTAssertFalse(PromptContextSanitizer.containsAlphanumericSignal(""))
    }
}
