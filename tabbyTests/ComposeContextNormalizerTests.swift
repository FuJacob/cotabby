import XCTest
@testable import tabby

/// Tests the pure cleanup layer that makes broad Accessibility text safe to include in Compose prompts.
final class ComposeContextNormalizerTests: XCTestCase {
    func test_normalize_collapsesWhitespaceAndPreservesLineStructure() {
        let normalized = ComposeContextNormalizer.normalize(
            " First\t\tline  with   spaces \n\nSecond line "
        )

        XCTAssertEqual(normalized, "First line with spaces\nSecond line")
    }

    func test_normalize_dropsSymbolNoiseAndObviousNavigationLines() {
        let normalized = ComposeContextNormalizer.normalize(
            "Share\n---\nThis is the useful page context.\nSkip to content\n**"
        )

        XCTAssertEqual(normalized, "This is the useful page context.")
    }

    func test_normalize_deduplicatesRepeatedLines() {
        let normalized = ComposeContextNormalizer.normalize(
            "A review comment\nA review comment\nAnother detail\nA review comment"
        )

        XCTAssertEqual(normalized, "A review comment\nAnother detail")
    }

    func test_normalize_boundsIndividualLinesAndFinalContext() {
        let limits = ComposeContextNormalizer.Limits(
            maxLineCharacters: 10,
            maxContextCharacters: 18
        )

        let normalized = ComposeContextNormalizer.normalize(
            "abcdefghijklmnopqrstuvwxyz\nsecond useful line",
            limits: limits
        )

        XCTAssertEqual(normalized, "abcdefghij...\nseco")
    }
}
