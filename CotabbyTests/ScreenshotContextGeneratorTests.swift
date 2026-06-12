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
        // Mirror the real extractor: split into per-line OCR with a confidence above the hygiene
        // threshold, so these cases keep exercising the non-confidence filters exactly as before.
        let lines = extractedText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { OCRTextHygiene.OCRLine(text: String($0), confidence: 0.9) }
        return makeGenerator(
            extracted: ExtractedScreenText(text: extractedText, lineCount: lines.count, lines: lines),
            configuration: configuration
        )
    }

    private func makeGenerator(
        lines: [OCRTextHygiene.OCRLine],
        configuration: VisualContextConfiguration = .default
    ) -> ScreenshotContextGenerator {
        let joined = lines.map(\.text).joined(separator: "\n")
        return makeGenerator(
            extracted: ExtractedScreenText(text: joined, lineCount: lines.count, lines: lines),
            configuration: configuration
        )
    }

    private func makeGenerator(
        extracted: ExtractedScreenText,
        configuration: VisualContextConfiguration
    ) -> ScreenshotContextGenerator {
        ScreenshotContextGenerator(
            screenshotService: StubScreenshotCapture(
                screenshot: CapturedWindowScreenshot(image: makeImage(), windowTitle: nil)
            ),
            textExtractor: StubTextExtractor(result: .success(extracted)),
            configuration: configuration
        )
    }

    func test_generateContext_dropsLowConfidenceOCRLines() async throws {
        // A clean, plausible sentence at low confidence must be dropped even though no other hygiene
        // filter would catch it, proving real per-line Vision confidence now reaches the hygiene pass.
        let configuration = VisualContextConfiguration(
            snapshotDimension: 700,
            maxImageDimension: 1600,
            minRecognizedCharacterCount: 12,
            maxRecognizedCharacters: 500,
            maxSummaryCharacters: 200
        )
        let generator = makeGenerator(
            lines: [
                OCRTextHygiene.OCRLine(text: "The quarterly report is due on Friday afternoon.", confidence: 0.2),
                OCRTextHygiene.OCRLine(text: "Please review the attached budget spreadsheet carefully.", confidence: 0.95)
            ],
            configuration: configuration
        )

        let excerpt = try await generator.generateContext(for: makeSnapshot())

        XCTAssertFalse(excerpt.text.contains("quarterly report"))
        XCTAssertTrue(excerpt.text.contains("budget spreadsheet"))
    }

    // MARK: - OCR-empty fallback to the window title

    private func makeGenerator(
        extractionError: Error,
        windowTitle: String?
    ) -> ScreenshotContextGenerator {
        ScreenshotContextGenerator(
            screenshotService: StubScreenshotCapture(
                screenshot: CapturedWindowScreenshot(image: makeImage(), windowTitle: windowTitle)
            ),
            textExtractor: StubTextExtractor(result: .failure(extractionError)),
            configuration: .default
        )
    }

    func test_generateContext_noRecognizedTextFallsBackToTheWindowTitle() async throws {
        // A screenshot of an image-heavy window can OCR to nothing while its title still names
        // the document; the title is the last usable signal before giving up.
        let generator = makeGenerator(
            extractionError: ScreenTextExtractionError.noRecognizedText,
            windowTitle: "Quarterly budget review draft for the finance meeting"
        )

        let excerpt = try await generator.generateContext(for: makeSnapshot())

        XCTAssertTrue(excerpt.text.contains("Quarterly budget review"))
    }

    func test_generateContext_noRecognizedTextWithoutATitleIsUnavailable() async {
        let generator = makeGenerator(
            extractionError: ScreenTextExtractionError.noRecognizedText,
            windowTitle: nil
        )

        do {
            _ = try await generator.generateContext(for: makeSnapshot())
            XCTFail("Expected unavailable")
        } catch let error as ScreenshotContextGenerationError {
            XCTAssertTrue(error.localizedDescription.contains("not contain enough visible text"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_generateContext_noRecognizedTextWithAJunkTitleIsUnavailable() async {
        // A title with no meaningful signal (window chrome noise) must not be promoted to prompt
        // context just because OCR came up empty.
        let generator = makeGenerator(
            extractionError: ScreenTextExtractionError.noRecognizedText,
            windowTitle: "x1 9z"
        )

        do {
            _ = try await generator.generateContext(for: makeSnapshot())
            XCTFail("Expected unavailable")
        } catch is ScreenshotContextGenerationError {
            // Expected: the junk title fails the meaningful-signal gate.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_generateContext_unexpectedExtractionErrorSurfacesAsFailed() async {
        struct VisionExploded: Error {}
        let generator = makeGenerator(extractionError: VisionExploded(), windowTitle: nil)

        do {
            _ = try await generator.generateContext(for: makeSnapshot())
            XCTFail("Expected failure")
        } catch let error as ScreenshotContextGenerationError {
            if case .failed = error {
                // Non-extraction errors keep their distinct "failed" classification.
            } else {
                XCTFail("Expected .failed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
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
