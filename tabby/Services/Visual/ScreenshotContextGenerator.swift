import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import ImageIO

/// File overview:
/// Converts a newly focused input's surrounding screenshot into OCR text for prompt injection.
/// The pipeline is now intentionally direct: focused snapshot -> screenshot crop -> Apple OCR ->
/// normalized visible-text excerpt.
///
/// This keeps the visual-context subsystem fast and conceptually honest. If Tabby later gains
/// true multimodal support, this file remains the seam where OCR can be replaced.
///
/// DEPRECATED:
/// Suggestion requests no longer consume screenshot/OCR text. This generator is retained only as
/// legacy scaffolding until the rebuilt context pipeline is implemented.

enum ScreenshotContextGenerationError: LocalizedError {
    case unavailable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .failed(let message):
            return message
        }
    }
}

@MainActor
final class ScreenshotContextGenerator {
    private let screenshotService: WindowScreenshotService
    private let textExtractor: ScreenTextExtractor
    private let summarizer: VisualContextSummarizing?
    private let configuration: VisualContextConfiguration

    init(
        screenshotService: WindowScreenshotService? = nil,
        textExtractor: ScreenTextExtractor? = nil,
        summarizer: VisualContextSummarizing? = nil,
        configuration: VisualContextConfiguration? = nil
    ) {
        let actualConfig = configuration ?? .default
        self.screenshotService = screenshotService ?? WindowScreenshotService()
        self.textExtractor =
            textExtractor
            ?? ScreenTextExtractor(
                maxImageDimension: actualConfig.maxImageDimension,
                maxRecognizedCharacters: actualConfig.maxRecognizedCharacters
            )
        self.summarizer = summarizer
        self.configuration = actualConfig
    }

    /// Captures a compact region around the focused input, runs OCR, and returns normalized visible
    /// text that can be injected directly into the completion prompt.
    func generateContext(
        for context: FocusedInputSnapshot,
        onStatusChange: (@Sendable (VisualContextStatus) async -> Void)? = nil
    ) async throws -> VisualContextExcerpt {
        log(
            "context-start app=\(context.applicationName) pid=\(context.processIdentifier) element=\(context.elementIdentifier)"
        )
        await onStatusChange?(.capturing)

        let screenshot: CapturedWindowScreenshot
        do {
            screenshot = try await screenshotService.captureSnapshot(
                around: context,
                snapshotDimension: configuration.snapshotDimension
            )
        } catch let error as WindowScreenshotError {
            log("context-capture-failed reason=\(error.localizedDescription)")
            throw ScreenshotContextGenerationError.unavailable(error.localizedDescription)
        } catch {
            log("context-capture-failed reason=\(error.localizedDescription)")
            throw ScreenshotContextGenerationError.failed(error.localizedDescription)
        }

        log(
            "context-captured title=\(screenshot.windowTitle ?? "<untitled>") "
                + "image=\(screenshot.image.width)x\(screenshot.image.height)"
        )

        await onStatusChange?(.extractingText)

        let extractedText: String
        do {
            extractedText = try await textExtractor.extractText(from: screenshot.image).text
        } catch ScreenTextExtractionError.noRecognizedText {
            guard let windowTitle = screenshot.windowTitle,
                hasMeaningfulSignal(windowTitle)
            else {
                log("context-ocr-unavailable no-recognized-text-and-weak-window-title")
                throw ScreenshotContextGenerationError.unavailable(
                    "The screenshot did not contain enough visible text to build prompt context."
                )
            }

            let fallbackText = normalizeRecognizedText(windowTitle)
            log("context-ocr-empty using-window-title-fallback")
            return VisualContextExcerpt(text: fallbackText)
        } catch let error as ScreenTextExtractionError {
            log("context-ocr-failed reason=\(error.localizedDescription)")
            throw ScreenshotContextGenerationError.unavailable(error.localizedDescription)
        } catch {
            log("context-ocr-failed reason=\(error.localizedDescription)")
            throw ScreenshotContextGenerationError.failed(error.localizedDescription)
        }

        let normalizedText = normalizeRecognizedText(extractedText)
        log("context-ocr-ready chars=\(normalizedText.count)")

        #if DEBUG
        saveDebugScreenshot(screenshot.image, text: extractedText, name: context.applicationName.replacingOccurrences(of: " ", with: "_"))
        #endif

        guard hasMeaningfulSignal(normalizedText) else {
            log("context-unavailable weak-screenshot-signal")
            throw ScreenshotContextGenerationError.unavailable(
                "The screenshot did not contain enough visible text to build prompt context."
            )
        }
        
        let finalContextText: String
        if let summarizer = summarizer {
            await onStatusChange?(.summarizingText)
            do {
                finalContextText = try await summarizer.summarize(text: normalizedText, applicationName: context.applicationName)
            } catch {
                log("context-summarization-failed reason=\(error.localizedDescription)")
                throw ScreenshotContextGenerationError.failed("Summarization failed: \(error.localizedDescription)")
            }
        } else {
            finalContextText = normalizedText
        }

        log("context-ready text=\(preview(finalContextText))")

        return VisualContextExcerpt(
            text: finalContextText
        )
    }

    /// OCR is noisy by nature. We normalize line whitespace and keep only a bounded excerpt so the
    /// completion prompt receives nearby visible text, not an unbounded UI dump.
    private func normalizeRecognizedText(_ rawText: String) -> String {
        let lines =
            rawText
            .replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: .newlines)
            .map {
                $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        let joinedText = lines.joined(separator: "\n")
        return String(joinedText.prefix(configuration.maxRecognizedCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// We reject OCR text that is mostly punctuation or numeric noise because that would hurt
    /// the completion prompt more than help it.
    private func hasMeaningfulSignal(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= configuration.minRecognizedCharacterCount else {
            return false
        }

        let letterCount = trimmed.unicodeScalars.filter(CharacterSet.letters.contains).count
        return letterCount >= 4
    }

    private func log(_ message: String) {
        _ = message
    }

    private func saveDebugScreenshot(_ image: CGImage, text: String, name: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tabby-debug-screenshots")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let timestamp = formatter.string(from: Date())
        
        let fileURL = url.appendingPathComponent("\(name)_\(timestamp).png")
        let textURL = url.appendingPathComponent("\(name)_\(timestamp).txt")
        
        if let dest = CGImageDestinationCreateWithURL(fileURL as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
            print("[DEBUG] Saved screenshot to: \(fileURL.path)")
            
            try? text.write(to: textURL, atomically: true, encoding: .utf8)
        }
    }

    private func preview(_ text: String) -> String {
        let compact = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.count <= 80 {
            return compact
        }

        let cut = compact.index(compact.startIndex, offsetBy: 80)
        return "\(compact[..<cut])..."
    }
}
