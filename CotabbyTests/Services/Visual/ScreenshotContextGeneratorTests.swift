import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for the screenshot -> OCR -> bounded-excerpt pipeline in `ScreenshotContextGenerator`.
///
/// Capture and Vision are replaced by in-file doubles, so these cases pin the generator's own
/// policy: privacy profile selection, OCR hygiene and bounding, the pixel-hash extraction cache,
/// the window-title fallback, and how capture/OCR failures are classified.
@MainActor
final class ScreenshotContextGeneratorTests: XCTestCase {
    private static let meaningfulLine =
        "GeneralPaneView.swift should say Screen Recording is required for autocomplete context"

    // MARK: - Privacy profile and bounding

    func test_localProfileCapturesFullWindowAndDoesNotReuseLowerResolutionEndpointOCR() async throws {
        let lines = (0..<80).map { OCRTextHygiene.OCRLine(text: "Project agenda item \($0)", confidence: 1) }
        let extractor = CountingTextExtractor(extracted: extracted(lines))
        let capture = RecordingScreenshotCapture(image: makeImage())
        let generator = ScreenshotContextGenerator(screenshotService: capture, textExtractor: extractor)

        let endpoint = try await generator.generateContext(for: makeSnapshot(), configuration: .default)
        let local = try await generator.generateContext(for: makeSnapshot(), configuration: .local)
        _ = try await generator.generateContext(for: makeSnapshot(), configuration: .local)

        XCTAssertEqual(capture.fullWindowRequests, [false, true, true])
        // The cache is keyed on configuration too: the endpoint crop's OCR never serves `.local`.
        XCTAssertEqual(extractor.extractionCount, 2)
        XCTAssertLessThanOrEqual(endpoint.text.count, 1500)
        XCTAssertFalse(endpoint.text.contains("item 79"))
        XCTAssertTrue(local.text.contains("item 79"))
        XCTAssertLessThanOrEqual(local.text.count, 4000)
    }

    func test_generateContext_ocrTextIsCappedAndSanitized() async throws {
        let configuration = makeConfiguration(maxSummaryCharacters: 60)
        let generator = makeGenerator(
            extracted: extracted(text: "gLVWrt bDokE 54tbdbDX\n\(Self.meaningfulLine)"),
            configuration: configuration
        )

        let excerpt = try await generator.generateContext(for: makeSnapshot())

        XCTAssertLessThanOrEqual(excerpt.text.count, configuration.maxSummaryCharacters)
        XCTAssertFalse(excerpt.text.contains("gLVWrt"))
        XCTAssertFalse(excerpt.text.contains("54tbdbDX"))
        XCTAssertTrue(excerpt.text.contains("GeneralPaneView.swift"))
    }

    func test_generateContext_allNoiseOCRReturnsUnavailable() async {
        let generator = makeGenerator(extracted: extracted(text: "gLVWrt bDokE 54tbdbDX\n50 424 102 99"))

        await assertUnavailable(generator, containing: "not contain enough visible text")
    }

    func test_generateContext_dropsLowConfidenceOCRLines() async throws {
        // A clean, plausible sentence at low confidence must be dropped even though no other hygiene
        // filter would catch it, proving real per-line Vision confidence reaches the hygiene pass.
        let generator = makeGenerator(
            extracted: extracted([
                OCRTextHygiene.OCRLine(text: "The quarterly report is due on Friday afternoon.", confidence: 0.2),
                OCRTextHygiene.OCRLine(text: "Please review the attached budget spreadsheet carefully.", confidence: 0.95)
            ]),
            configuration: makeConfiguration(maxSummaryCharacters: 200)
        )

        let excerpt = try await generator.generateContext(for: makeSnapshot())

        XCTAssertFalse(excerpt.text.contains("quarterly report"))
        XCTAssertTrue(excerpt.text.contains("budget spreadsheet"))
    }

    func test_generateContext_reportsCapturingThenExtractingStatus() async throws {
        let generator = makeGenerator(extracted: extracted(text: Self.meaningfulLine))
        let recorder = StatusRecorder()

        _ = try await generator.generateContext(
            for: makeSnapshot(),
            configuration: nil,
            onStatusChange: { recorder.statuses.append($0) }
        )

        // `.ready` is the coordinator's transition to publish, not the generator's.
        XCTAssertEqual(recorder.statuses, [.capturing, .extractingText])
    }

    // MARK: - Extraction cache

    func test_generateContext_reusesExtractionForIdenticalPixels() async throws {
        let extractor = CountingTextExtractor(extracted: extracted(text: Self.meaningfulLine))
        let generator = ScreenshotContextGenerator(
            screenshotService: RecordingScreenshotCapture(image: makeImage()),
            textExtractor: extractor,
            configuration: .default
        )

        let first = try await generator.generateContext(for: makeSnapshot())
        let second = try await generator.generateContext(for: makeSnapshot())

        XCTAssertEqual(extractor.extractionCount, 1, "Pixel-identical recaptures must skip the Vision pass.")
        XCTAssertEqual(first.text, second.text, "A cache hit must produce the same excerpt as a fresh OCR.")
    }

    func test_generateContext_cacheHoldsTheFourMostRecentCrops() async throws {
        let extractor = CountingTextExtractor(extracted: extracted(text: Self.meaningfulLine))
        let capture = RecordingScreenshotCapture(image: makeImage())
        let generator = ScreenshotContextGenerator(
            screenshotService: capture,
            textExtractor: extractor,
            configuration: .default
        )

        // Width is mixed into the pixel hash, so each width is a distinct cache key.
        func generate(width: Int) async throws {
            capture.image = makeImage(width: width)
            _ = try await generator.generateContext(for: makeSnapshot())
        }

        for width in 1...5 {
            try await generate(width: width)
        }
        XCTAssertEqual(extractor.extractionCount, 5, "Distinct pixels always miss")

        try await generate(width: 1)
        XCTAssertEqual(extractor.extractionCount, 6, "The oldest crop was evicted by the fifth entry")

        try await generate(width: 5)
        XCTAssertEqual(extractor.extractionCount, 6, "Recent crops stay cached")
    }

    // MARK: - Focused field exclusion

    /// A composer across the bottom quarter of the middle half of a 40x20 capture: pixel columns
    /// 10..<30 and rows 15..<20 counted from the top, or y 0...5 in the bitmap context's coordinates.
    private static let composer = FocusedFieldScreenRegion(bounds: CGRect(x: 0.25, y: 0, width: 0.5, height: 0.25))!
    private static let conversationLine =
        OCRTextHygiene.OCRLine(text: meaningfulLine, confidence: 0.9, boundingBox: CGRect(x: 0.1, y: 0.6, width: 0.8, height: 0.05))

    /// The composer's own text as Vision reads it, centered inside `composer`.
    private static func typedLine(_ text: String) -> OCRTextHygiene.OCRLine {
        OCRTextHygiene.OCRLine(text: text, confidence: 0.9, boundingBox: CGRect(x: 0.3, y: 0.1, width: 0.3, height: 0.05))
    }

    func test_generateContext_dropsTheFieldsOwnLineThatTheEchoStripMisses() async throws {
        // The screenshot lands a keystroke after the snapshot ("Screen Recording"), so the typed
        // line is not a substring of the field text. Only its position identifies it, in both the
        // local (selector) and endpoint (hygiene) profiles; without a region it leaks through.
        let lines = [Self.conversationLine, Self.typedLine("Screen Recording permission")]
        for configuration in [VisualContextConfiguration.local, .default] {
            for region in [Self.composer, nil] {
                let capture = RecordingScreenshotCapture(image: makeImage(width: 40, height: 20))
                capture.fieldRegion = region
                let generator = ScreenshotContextGenerator(
                    screenshotService: capture,
                    textExtractor: StubTextExtractor(result: .success(extracted(lines)))
                )

                let excerpt = try await generator.generateContext(for: makeSnapshot(), configuration: configuration)

                XCTAssertTrue(excerpt.text.contains("GeneralPaneView"))
                XCTAssertEqual(excerpt.text.contains("permission"), region == nil, "\(configuration) region=\(String(describing: region))")
            }
        }
    }

    func test_generateContext_typingInsideTheFieldReusesOCRAndKeepsTheExcerptIdentical() async throws {
        // Vision would read the new keystrokes, but the recapture differs only inside the field,
        // so it must not reach Vision at all: the excerpt stays byte-identical and the suggestion
        // coordinator sees no change to treat as navigation.
        let extractor = SequencedTextExtractor([
            extracted([Self.conversationLine, Self.typedLine("Screen Recording permission")]),
            extracted([Self.conversationLine, Self.typedLine("Screen Recording permission is required")])
        ])
        let capture = RecordingScreenshotCapture(image: makeImage(width: 40, height: 20))
        capture.fieldRegion = Self.composer
        let generator = ScreenshotContextGenerator(screenshotService: capture, textExtractor: extractor, configuration: .local)

        let first = try await generator.generateContext(for: makeSnapshot())
        capture.image = makeImage(width: 40, height: 20, painting: CGRect(x: 12, y: 1, width: 10, height: 3))
        let second = try await generator.generateContext(for: makeSnapshot(precedingText: "Screen Recording permission"))

        XCTAssertEqual(extractor.extractionCount, 1, "A typing-only recapture must reuse the previous OCR")
        XCTAssertEqual(first.text, second.text)

        // Control: the same keystroke pixels are a real change when no field region is known.
        capture.fieldRegion = nil
        capture.image = makeImage(width: 40, height: 20)
        _ = try await generator.generateContext(for: makeSnapshot())
        capture.image = makeImage(width: 40, height: 20, painting: CGRect(x: 12, y: 1, width: 10, height: 3))
        _ = try await generator.generateContext(for: makeSnapshot())
        XCTAssertEqual(extractor.extractionCount, 3)
    }

    func test_generateContext_aChangeOutsideTheFieldStillReachesTheExcerpt() async throws {
        // Navigation intent: a different conversation above the composer must re-run OCR and
        // change the excerpt even while the field is excluded.
        let newMessage = "Please review the attached budget spreadsheet before the meeting"
        let extractor = SequencedTextExtractor([
            extracted([Self.conversationLine, Self.typedLine("Screen Recording permission")]),
            extracted([
                OCRTextHygiene.OCRLine(text: newMessage, confidence: 0.9, boundingBox: Self.conversationLine.boundingBox),
                Self.typedLine("Screen Recording permission")
            ])
        ])
        let capture = RecordingScreenshotCapture(image: makeImage(width: 40, height: 20))
        capture.fieldRegion = Self.composer
        let generator = ScreenshotContextGenerator(screenshotService: capture, textExtractor: extractor, configuration: .local)

        _ = try await generator.generateContext(for: makeSnapshot())
        capture.image = makeImage(width: 40, height: 20, painting: CGRect(x: 2, y: 10, width: 10, height: 6))
        let second = try await generator.generateContext(for: makeSnapshot())

        XCTAssertEqual(extractor.extractionCount, 2)
        XCTAssertEqual(second.text, newMessage)
    }

    func test_generateContext_aMovedFieldMissesTheCache() async throws {
        // Cached lines are only ever judged against the field geometry they were recognized with:
        // a composer that grew by a line re-runs OCR even if nothing outside it changed.
        let extractor = CountingTextExtractor(extracted: extracted([Self.conversationLine]))
        let capture = RecordingScreenshotCapture(image: makeImage(width: 40, height: 20))
        capture.fieldRegion = Self.composer
        let generator = ScreenshotContextGenerator(screenshotService: capture, textExtractor: extractor, configuration: .local)

        _ = try await generator.generateContext(for: makeSnapshot())
        capture.fieldRegion = FocusedFieldScreenRegion(bounds: CGRect(x: 0.25, y: 0, width: 0.5, height: 0.35))
        _ = try await generator.generateContext(for: makeSnapshot())

        XCTAssertEqual(extractor.extractionCount, 2)
    }

    // MARK: - OCR-empty fallback to the window title

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

    func test_generateContext_noRecognizedTextWithoutAUsableTitleIsUnavailable() async {
        // A missing title and a title with no meaningful signal (window chrome noise) must both
        // give up rather than promote junk to prompt context.
        for windowTitle in [nil, "x1 9z"] as [String?] {
            let generator = makeGenerator(
                extractionError: ScreenTextExtractionError.noRecognizedText,
                windowTitle: windowTitle
            )

            await assertUnavailable(generator, containing: "not contain enough visible text")
        }
    }

    // MARK: - Error classification

    func test_generateContext_ocrFailureSurfacesAsUnavailableWithItsDescription() async {
        let generator = makeGenerator(extractionError: ScreenTextExtractionError.ocrFailed("boom"), windowTitle: nil)

        await assertUnavailable(generator, containing: "Screenshot OCR failed: boom")
    }

    func test_generateContext_unexpectedExtractionErrorSurfacesAsFailed() async {
        struct VisionExploded: Error {}
        let generator = makeGenerator(extractionError: VisionExploded(), windowTitle: nil)

        await assertFailed(generator)
    }

    func test_generateContext_screenshotErrorSurfacesAsUnavailableAndSkipsOCR() async {
        let capture = RecordingScreenshotCapture(image: makeImage())
        capture.error = WindowScreenshotError.screenRecordingPermissionMissing
        let extractor = CountingTextExtractor(extracted: extracted(text: Self.meaningfulLine))
        let generator = ScreenshotContextGenerator(screenshotService: capture, textExtractor: extractor)

        await assertUnavailable(generator, containing: "Screen Recording permission is required")
        XCTAssertEqual(extractor.extractionCount, 0)
    }

    func test_generateContext_unexpectedCaptureErrorSurfacesAsFailed() async {
        struct CaptureExploded: Error {}
        let capture = RecordingScreenshotCapture(image: makeImage())
        capture.error = CaptureExploded()
        let generator = ScreenshotContextGenerator(
            screenshotService: capture,
            textExtractor: CountingTextExtractor(extracted: extracted(text: Self.meaningfulLine))
        )

        await assertFailed(generator)
    }

    // MARK: - Helpers

    private func makeConfiguration(maxSummaryCharacters: Int) -> VisualContextConfiguration {
        VisualContextConfiguration(
            snapshotDimension: 700,
            maxImageDimension: 1600,
            minRecognizedCharacterCount: 12,
            maxRecognizedCharacters: 500,
            maxSummaryCharacters: maxSummaryCharacters
        )
    }

    private func extracted(_ lines: [OCRTextHygiene.OCRLine]) -> ExtractedScreenText {
        ExtractedScreenText(text: lines.map(\.text).joined(separator: "\n"), lineCount: lines.count, lines: lines)
    }

    /// Mirrors the real extractor: one OCR line per text line, with a confidence above the hygiene
    /// threshold so these cases exercise the non-confidence filters.
    private func extracted(text: String) -> ExtractedScreenText {
        extracted(
            text.split(separator: "\n", omittingEmptySubsequences: true)
                .map { OCRTextHygiene.OCRLine(text: String($0), confidence: 0.9) }
        )
    }

    private func makeGenerator(
        extracted: ExtractedScreenText,
        configuration: VisualContextConfiguration = .default
    ) -> ScreenshotContextGenerator {
        ScreenshotContextGenerator(
            screenshotService: RecordingScreenshotCapture(image: makeImage()),
            textExtractor: StubTextExtractor(result: .success(extracted)),
            configuration: configuration
        )
    }

    private func makeGenerator(extractionError: Error, windowTitle: String?) -> ScreenshotContextGenerator {
        ScreenshotContextGenerator(
            screenshotService: RecordingScreenshotCapture(image: makeImage(), windowTitle: windowTitle),
            textExtractor: StubTextExtractor(result: .failure(extractionError)),
            configuration: .default
        )
    }

    private func assertUnavailable(
        _ generator: ScreenshotContextGenerator,
        containing expectedMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await generator.generateContext(for: makeSnapshot())
            XCTFail("Expected unavailable", file: file, line: line)
        } catch ScreenshotContextGenerationError.unavailable(let message) {
            XCTAssertTrue(message.contains(expectedMessage), "Got: \(message)", file: file, line: line)
        } catch {
            XCTFail("Expected .unavailable, got \(error)", file: file, line: line)
        }
    }

    private func assertFailed(
        _ generator: ScreenshotContextGenerator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await generator.generateContext(for: makeSnapshot())
            XCTFail("Expected failure", file: file, line: line)
        } catch ScreenshotContextGenerationError.failed {
            // Errors outside the capture/OCR vocabularies keep their distinct "failed" classification.
        } catch {
            XCTFail("Expected .failed, got \(error)", file: file, line: line)
        }
    }

    private func makeSnapshot(precedingText: String = "Screen Recording") -> FocusedInputSnapshot {
        CotabbyTestFixtures.focusedInputSnapshot(
            applicationName: "Xcode",
            bundleIdentifier: "com.apple.dt.Xcode",
            elementIdentifier: "test-field",
            role: "AXTextArea",
            caretRect: CGRect(x: 140, y: 420, width: 2, height: 18),
            inputFrameRect: CGRect(x: 100, y: 380, width: 600, height: 120),
            precedingText: precedingText
        )
    }

    /// A white image, optionally with one black rectangle in bitmap-context coordinates (origin at
    /// the bottom-left, the same orientation as Vision's normalized boxes).
    private func makeImage(width: Int = 1, height: Int = 1, painting blackRect: CGRect? = nil) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let blackRect {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(blackRect)
        }
        return context.makeImage()!
    }
}

/// Serves a configurable screenshot (or error) and records which capture profile was requested.
@MainActor
private final class RecordingScreenshotCapture: WindowScreenshotCapturing {
    var image: CGImage
    let windowTitle: String?
    var fieldRegion: FocusedFieldScreenRegion?
    var error: Error?
    private(set) var fullWindowRequests: [Bool] = []

    init(image: CGImage, windowTitle: String? = nil) {
        self.image = image
        self.windowTitle = windowTitle
    }

    func captureSnapshot(
        around context: FocusedInputSnapshot,
        snapshotDimension: Int,
        capturesEntireWindow: Bool
    ) async throws -> CapturedWindowScreenshot {
        fullWindowRequests.append(capturesEntireWindow)
        if let error {
            throw error
        }
        return CapturedWindowScreenshot(image: image, windowTitle: windowTitle, fieldRegion: fieldRegion)
    }
}

/// Returns its extractions in order (repeating the last), the way Vision would re-read a changed
/// field, and counts passes so a cache hit is visible as a skipped result.
@MainActor
private final class SequencedTextExtractor: ScreenTextExtracting {
    private let results: [ExtractedScreenText]
    private(set) var extractionCount = 0

    init(_ results: [ExtractedScreenText]) {
        self.results = results
    }

    func extractText(from image: CGImage) async throws -> ExtractedScreenText {
        defer { extractionCount += 1 }
        return results[min(extractionCount, results.count - 1)]
    }
}

/// Counts Vision-pass invocations so the pixel-hash extraction cache can be asserted on.
@MainActor
private final class CountingTextExtractor: ScreenTextExtracting {
    private let extracted: ExtractedScreenText
    private(set) var extractionCount = 0

    init(extracted: ExtractedScreenText) {
        self.extracted = extracted
    }

    func extractText(from image: CGImage) async throws -> ExtractedScreenText {
        extractionCount += 1
        return extracted
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

@MainActor
private final class StatusRecorder {
    var statuses: [VisualContextStatus] = []
}
