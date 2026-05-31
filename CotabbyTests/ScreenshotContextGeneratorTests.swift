import CoreGraphics
import XCTest
@testable import Cotabby

@MainActor
final class ScreenshotContextGeneratorTests: XCTestCase {
    func test_generateContext_usesGoodSummaryWhenAvailable() async throws {
        let generator = makeGenerator(
            extractedText: "Issue 471 asks Cotabby to improve suggestions in GeneralPaneView.swift",
            summaryResult: .success("Surface Xcode task update Screen Recording permission copy")
        )

        let excerpt = try await generator.generateContext(for: makeSnapshot())

        XCTAssertTrue(excerpt.text.contains("Surface Xcode task"))
        XCTAssertFalse(excerpt.text.contains("Issue 471"))
    }

    func test_generateContext_emptySummaryFallsBackToSanitizedOCR() async throws {
        let generator = makeGenerator(
            extractedText: "Issue 471 asks Cotabby to improve suggestions in GeneralPaneView.swift",
            summaryResult: .success("   ")
        )

        let excerpt = try await generator.generateContext(for: makeSnapshot())

        XCTAssertTrue(excerpt.text.contains("Issue"))
        XCTAssertTrue(excerpt.text.contains("GeneralPaneView.swift"))
    }

    func test_generateContext_thrownSummarizerErrorFallsBackToSanitizedOCR() async throws {
        let generator = makeGenerator(
            extractedText: "GitHub PR needs exact context about ScreenshotContextGenerator.swift",
            summaryResult: .failure
        )

        let excerpt = try await generator.generateContext(for: makeSnapshot())

        XCTAssertTrue(excerpt.text.contains("GitHub PR"))
        XCTAssertTrue(excerpt.text.contains("ScreenshotContextGenerator.swift"))
    }

    func test_generateContext_ocrOnlyFallbackIsCappedAndSanitized() async throws {
        let configuration = VisualContextConfiguration(
            snapshotDimension: 700,
            maxImageDimension: 1600,
            minRecognizedCharacterCount: 12,
            maxRecognizedCharacters: 500,
            maxSummaryCharacters: 60
        )
        let generator = makeGenerator(
            extractedText: """
            gLVWrt bDokE 54tbdbDX
            GeneralPaneView.swift should say Screen Recording is required for autocomplete context
            """,
            summaryResult: nil,
            configuration: configuration
        )

        let excerpt = try await generator.generateContext(for: makeSnapshot())

        XCTAssertLessThanOrEqual(excerpt.text.count, configuration.maxSummaryCharacters)
        XCTAssertFalse(excerpt.text.contains("gLVWrt"))
        XCTAssertFalse(excerpt.text.contains("54tbdbDX"))
        XCTAssertTrue(excerpt.text.contains("GeneralPaneView.swift"))
    }

    func test_generateContext_allNoiseOCRReturnsUnavailable() async throws {
        let generator = makeGenerator(
            extractedText: "gLVWrt bDokE 54tbdbDX\n50 424 102 99",
            summaryResult: nil
        )

        do {
            _ = try await generator.generateContext(for: makeSnapshot())
            XCTFail("Expected all-noise OCR to be unavailable.")
        } catch let error as ScreenshotContextGenerationError {
            XCTAssertTrue(error.localizedDescription.contains("not contain enough visible text"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeGenerator(
        extractedText: String,
        summaryResult: StubSummarizer.Result?,
        configuration: VisualContextConfiguration = .default
    ) -> ScreenshotContextGenerator {
        ScreenshotContextGenerator(
            screenshotService: StubScreenshotCapture(
                screenshot: CapturedWindowScreenshot(image: makeImage(), windowTitle: nil)
            ),
            textExtractor: StubTextExtractor(
                result: .success(ExtractedScreenText(text: extractedText, lineCount: 1))
            ),
            summarizer: summaryResult.map(StubSummarizer.init(result:)),
            configuration: configuration
        )
    }

    private func makeSnapshot() -> FocusedInputSnapshot {
        FocusedInputSnapshot(
            applicationName: "Xcode",
            bundleIdentifier: "com.apple.dt.Xcode",
            processIdentifier: 123,
            elementIdentifier: "test-field",
            role: "AXTextArea",
            subrole: nil,
            caretRect: CGRect(x: 140, y: 420, width: 2, height: 18),
            inputFrameRect: CGRect(x: 100, y: 380, width: 600, height: 120),
            caretSource: "test",
            caretQuality: .exact,
            observedCharWidth: nil,
            precedingText: "Screen Recording",
            trailingText: "",
            selection: NSRange(location: 16, length: 0),
            isSecure: false
        )
    }

    private func makeImage() -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()!
    }
}

private struct StubScreenshotCapture: WindowScreenshotCapturing {
    let screenshot: CapturedWindowScreenshot

    func captureSnapshot(
        around context: FocusedInputSnapshot,
        snapshotDimension: Int
    ) async throws -> CapturedWindowScreenshot {
        screenshot
    }
}

private struct StubTextExtractor: ScreenTextExtracting {
    enum Result {
        case success(ExtractedScreenText)
        case failure(Error)
    }

    let result: Result

    func extractText(from image: CGImage) async throws -> ExtractedScreenText {
        switch result {
        case let .success(text):
            return text
        case let .failure(error):
            throw error
        }
    }
}

private final class StubSummarizer: VisualContextSummarizing {
    enum Result {
        case success(String)
        case failure
    }

    let result: Result

    init(result: Result) {
        self.result = result
    }

    func summarize(text: String, applicationName: String) async throws -> String {
        switch result {
        case let .success(summary):
            return summary
        case .failure:
            throw StubSummarizerError.failed
        }
    }
}

private enum StubSummarizerError: Error {
    case failed
}
