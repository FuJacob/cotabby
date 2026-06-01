import CoreGraphics
import Foundation
import ImageIO
import Logging
import UniformTypeIdentifiers

/// File overview:
/// Converts a newly focused input's surrounding screenshot into OCR text for prompt injection.
/// The pipeline is: focused snapshot -> screenshot crop -> Apple OCR -> optional local summary ->
/// bounded visible-context excerpt.
///
/// Keeping capture/OCR/summarization at this boundary gives the suggestion coordinator a small
/// plain-text value instead of exposing raw screenshots or OCR implementation details.

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
    private enum ContextSource: String {
        case ocrFallback = "ocr_fallback"
    }

    private let screenshotService: any WindowScreenshotCapturing
    private let textExtractor: any ScreenTextExtracting
    private let configuration: VisualContextConfiguration

    init(
        screenshotService: (any WindowScreenshotCapturing)? = nil,
        textExtractor: (any ScreenTextExtracting)? = nil,
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
        self.configuration = actualConfig
    }

    /// Captures a compact region around the focused input and returns a bounded text excerpt that
    /// can be injected into the completion prompt.
    func generateContext(
        for context: FocusedInputSnapshot,
        onStatusChange: (@Sendable (VisualContextStatus) async -> Void)? = nil
    ) async throws -> VisualContextExcerpt {
        let screenshot = try await captureScreenshot(for: context, onStatusChange: onStatusChange)

        await onStatusChange?(.extractingText)

        let extracted: ExtractedScreenText
        do {
            extracted = try await textExtractor.extractText(from: screenshot.image)
        } catch ScreenTextExtractionError.noRecognizedText {
            guard let windowTitle = screenshot.windowTitle else {
                throw ScreenshotContextGenerationError.unavailable(
                    "The screenshot did not contain enough visible text to build prompt context."
                )
            }

            let normalizedTitle = normalizeRecognizedText(windowTitle)
            guard hasMeaningfulSignal(normalizedTitle)
            else {
                throw ScreenshotContextGenerationError.unavailable(
                    "The screenshot did not contain enough visible text to build prompt context."
                )
            }

            let finalTitleContext = boundedSummaryText(normalizedTitle)
            CotabbyLogger.app.debug(
                "Visual context ready source=\(ContextSource.ocrFallback.rawValue) chars=\(finalTitleContext.count)"
            )
            return VisualContextExcerpt(text: finalTitleContext)
        } catch let error as ScreenTextExtractionError {
            throw ScreenshotContextGenerationError.unavailable(error.localizedDescription)
        } catch {
            throw ScreenshotContextGenerationError.failed(error.localizedDescription)
        }

        // Filter OCR corruption (garbled / symbol-noise / digit-substituted lines) and strip any
        // line that merely echoes the user's own field text, then sanitize for prompt-injection
        // safety. No model summarization: a base model conditions fine on cleaned raw context, and
        // the old summary step cost an extra generation per refresh and could hallucinate.
        let cleanedOCR = OCRTextHygiene.clean(
            lines: extracted.lines,
            fieldText: context.precedingText + " " + context.trailingText,
            maxChars: configuration.maxRecognizedCharacters
        )
        let normalizedText = normalizeRecognizedText(cleanedOCR)

        if CotabbyDebugOptions.isEnabled {
            saveDebugScreenshot(
                screenshot.image,
                text: extracted.text,
                name: sanitizedDebugName(from: context.applicationName)
            )
        }

        let finalContextText = boundedSummaryText(normalizedText)
        guard hasMeaningfulSignal(finalContextText) else {
            throw ScreenshotContextGenerationError.unavailable(
                "The screenshot did not contain enough visible text to build prompt context."
            )
        }

        CotabbyLogger.app.debug(
            "Visual context ready source=\(ContextSource.ocrFallback.rawValue) chars=\(finalContextText.count)"
        )

        return VisualContextExcerpt(text: finalContextText)
    }

    private func captureScreenshot(
        for context: FocusedInputSnapshot,
        onStatusChange: (@Sendable (VisualContextStatus) async -> Void)?
    ) async throws -> CapturedWindowScreenshot {
        await onStatusChange?(.capturing)
        do {
            return try await screenshotService.captureSnapshot(
                around: context,
                snapshotDimension: configuration.snapshotDimension
            )
        } catch let error as WindowScreenshotError {
            throw ScreenshotContextGenerationError.unavailable(error.localizedDescription)
        } catch {
            throw ScreenshotContextGenerationError.failed(error.localizedDescription)
        }
    }

    /// OCR is noisy by nature. We normalize line whitespace, strip short-token noise from UI
    /// chrome, and keep only a bounded excerpt so the summarizer receives meaningful text.
    private func normalizeRecognizedText(_ rawText: String) -> String {
        PromptContextSanitizer.sanitizeOCR(
            rawText,
            maxCharacters: configuration.maxRecognizedCharacters
        )
    }

    /// Applies the final prompt-injection budget after optional summarization.
    ///
    /// `maxRecognizedCharacters` protects the OCR and summarizer input. This separate cap protects
    /// the autocomplete prompt from a verbose model summary or from the raw-OCR fallback path.
    private func boundedSummaryText(_ text: String) -> String {
        PromptContextSanitizer.sanitize(
            text,
            maxCharacters: configuration.maxSummaryCharacters
        )
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

    /// Maximum number of debug capture pairs (png + txt) kept per application folder.
    private static let maxDebugCapturesPerApp = 20

    private func saveDebugScreenshot(_ image: CGImage, text: String, name: String) {
        guard let desktopURL = FileManager.default.urls(
            for: .desktopDirectory,
            in: .userDomainMask
        ).first else {
            return
        }

        let appFolderURL = desktopURL
            .appendingPathComponent("cotabby-debug-screenshots")
            .appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: appFolderURL, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy 'at' h.mm.ss.SSS a"
        let timestamp = formatter.string(from: Date())

        let fileURL = appFolderURL.appendingPathComponent("\(timestamp).png")
        let textURL = appFolderURL.appendingPathComponent("\(timestamp).txt")

        if let dest = CGImageDestinationCreateWithURL(
            fileURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) {
            CGImageDestinationAddImage(dest, image, nil)
            if CGImageDestinationFinalize(dest) {
                try? text.write(to: textURL, atomically: true, encoding: .utf8)
                evictOldDebugCaptures(in: appFolderURL)
            }
        }
    }

    /// Keeps only the newest `maxDebugCapturesPerApp` png+txt pairs per app folder,
    /// deleting the oldest files first (by creation date).
    private func evictOldDebugCaptures(in folderURL: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return
        }

        let pngFiles = contents
            .filter { $0.pathExtension == "png" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return lhsDate < rhsDate
            }

        let overflow = pngFiles.count - Self.maxDebugCapturesPerApp
        guard overflow > 0 else { return }

        for pngURL in pngFiles.prefix(overflow) {
            let txtURL = pngURL.deletingPathExtension().appendingPathExtension("txt")
            try? fm.removeItem(at: pngURL)
            try? fm.removeItem(at: txtURL)
        }
    }

    private func sanitizedDebugName(from rawName: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let replacement = UnicodeScalar("_")
        let sanitizedScalars = rawName.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? scalar : replacement
        }
        let sanitizedName = String(String.UnicodeScalarView(sanitizedScalars))
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return sanitizedName.isEmpty ? "unknown-app" : sanitizedName
    }
}
