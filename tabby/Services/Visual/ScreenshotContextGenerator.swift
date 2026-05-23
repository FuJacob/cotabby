import CoreGraphics
import Foundation
import ImageIO
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

    /// Captures a compact region around the focused input and returns a bounded text excerpt that
    /// can be injected into the completion prompt.
    func generateContext(
        for context: FocusedInputSnapshot,
        onStatusChange: (@Sendable (VisualContextStatus) async -> Void)? = nil
    ) async throws -> VisualContextExcerpt {
        await onStatusChange?(.capturing)

        let screenshot: CapturedWindowScreenshot
        do {
            screenshot = try await screenshotService.captureSnapshot(
                around: context,
                snapshotDimension: configuration.snapshotDimension
            )
        } catch let error as WindowScreenshotError {
            throw ScreenshotContextGenerationError.unavailable(error.localizedDescription)
        } catch {
            throw ScreenshotContextGenerationError.failed(error.localizedDescription)
        }

        await onStatusChange?(.extractingText)

        let extractedText: String
        do {
            extractedText = try await textExtractor.extractText(from: screenshot.image).text
        } catch ScreenTextExtractionError.noRecognizedText {
            guard let windowTitle = screenshot.windowTitle,
                hasMeaningfulSignal(windowTitle)
            else {
                throw ScreenshotContextGenerationError.unavailable(
                    "The screenshot did not contain enough visible text to build prompt context."
                )
            }

            return VisualContextExcerpt(
                text: boundedSummaryText(normalizeRecognizedText(windowTitle))
            )
        } catch let error as ScreenTextExtractionError {
            throw ScreenshotContextGenerationError.unavailable(error.localizedDescription)
        } catch {
            throw ScreenshotContextGenerationError.failed(error.localizedDescription)
        }

        let normalizedText = normalizeRecognizedText(extractedText)

        if TabbyDebugOptions.isEnabled {
            saveDebugScreenshot(
                screenshot.image,
                text: extractedText,
                name: sanitizedDebugName(from: context.applicationName)
            )
        }

        guard hasMeaningfulSignal(normalizedText) else {
            throw ScreenshotContextGenerationError.unavailable(
                "The screenshot did not contain enough visible text to build prompt context."
            )
        }

        let generatedContextText: String
        if let summarizer = summarizer {
            await onStatusChange?(.summarizingText)
            do {
                generatedContextText = try await summarizer.summarize(
                    text: normalizedText,
                    applicationName: context.applicationName
                )
            } catch {
                throw ScreenshotContextGenerationError.failed(
                    "Summarization failed: \(error.localizedDescription)"
                )
            }
        } else {
            generatedContextText = normalizedText
        }

        let finalContextText = boundedSummaryText(generatedContextText)
        guard hasMeaningfulSignal(finalContextText) else {
            throw ScreenshotContextGenerationError.unavailable(
                "The screenshot did not contain enough visible text to build prompt context."
            )
        }

        return VisualContextExcerpt(
            text: finalContextText
        )
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
            .appendingPathComponent("tabby-debug-screenshots")
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
