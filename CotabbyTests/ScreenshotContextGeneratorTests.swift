import CoreGraphics
import XCTest
@testable import Cotabby

@MainActor
final class ScreenshotContextGeneratorTests: XCTestCase {
    func test_generateContext_ocrTextIsCappedAndSanitized() async throws {
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
            configuration: configuration
        )

        let excerpt = try await generator.generateContext(for: makeSnapshot())

        XCTAssertLessThanOrEqual(excerpt.text.count, configuration.maxSummaryCharacters)
        XCTAssertFalse(excerpt.text.contains("gLVWrt"))
        XCTAssertFalse(excerpt.text.contains("54tbdbDX"))
        XCTAssertTrue(excerpt.text.contains("GeneralPaneView.swift"))
    }

    func test_generateContext_allNoiseOCRReturnsUnavailable() async throws {
        let generator = makeGenerator(extractedText: "gLVWrt bDokE 54tbdbDX\n50 424 102 99")

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
        configuration: VisualContextConfiguration = .default
    ) -> ScreenshotContextGenerator {
        ScreenshotContextGenerator(
            screenshotService: StubScreenshotCapture(
                screenshot: CapturedWindowScreenshot(image: makeImage(), windowTitle: nil)
            ),
            textExtractor: StubTextExtractor(
                result: .success(ExtractedScreenText(text: extractedText, lineCount: 1))
            ),
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
