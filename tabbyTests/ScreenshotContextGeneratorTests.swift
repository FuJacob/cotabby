import XCTest
@testable import tabby

/// Tests for the summary-vs-OCR selection rule inside the visual-context pipeline.
///
/// `ScreenshotContextGenerator` owns the boundary where noisy OCR can optionally be compressed by a
/// second local-model pass. These tests lock down the contract that summarization is preferred only
/// when it still carries real signal; otherwise the sanitized OCR fallback must survive.
@MainActor
final class ScreenshotContextGeneratorTests: XCTestCase {
    func test_preferredVisualContextText_keepsMeaningfulSummary() {
        let generator = ScreenshotContextGenerator(configuration: .default)

        let contextText = generator.preferredVisualContextText(
            summarizedText: "Aurora launch review\nCustomer requested Friday at 3 PM",
            fallbackText: "Raw OCR text that should not win"
        )

        XCTAssertEqual(
            contextText,
            "Aurora launch review\nCustomer requested Friday at 3 PM"
        )
    }

    func test_preferredVisualContextText_fallsBackWhenSummaryHasNoSignal() {
        let generator = ScreenshotContextGenerator(configuration: .default)

        let contextText = generator.preferredVisualContextText(
            summarizedText: "23h\nReply\nCopy",
            fallbackText: "Aurora launch review\nCustomer requested Friday at 3 PM"
        )

        XCTAssertEqual(
            contextText,
            "Aurora launch review\nCustomer requested Friday at 3 PM"
        )
    }
}
