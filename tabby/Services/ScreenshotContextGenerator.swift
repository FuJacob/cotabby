import CoreGraphics
import Foundation

/// File overview:
/// Converts a newly focused input's surrounding screenshot into a short prompt hint. Today this
/// uses a pragmatic pipeline: frontmost-window screenshot -> OCR -> same loaded local LLM summary.
///
/// This keeps the feature shippable with the current text-only runtime while preserving the shape
/// of a future direct multimodal implementation. If Tabby later gains true image-token support,
/// this file is where the OCR stage can be replaced.

enum ScreenshotContextGenerationError: LocalizedError {
    case unavailable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(message), let .failed(message):
            return message
        }
    }
}

@MainActor
final class ScreenshotContextGenerator {
    private let screenshotService: WindowScreenshotService
    private let textExtractor: ScreenTextExtractor
    private let runtimeManager: LlamaRuntimeManager
    private let configuration: VisualContextConfiguration

    init(
        screenshotService: WindowScreenshotService? = nil,
        textExtractor: ScreenTextExtractor? = nil,
        runtimeManager: LlamaRuntimeManager,
        configuration: VisualContextConfiguration? = nil
    ) {
        let actualConfig = configuration ?? .default
        self.screenshotService = screenshotService ?? WindowScreenshotService()
        self.textExtractor = textExtractor ?? ScreenTextExtractor(
            maxImageDimension: actualConfig.maxImageDimension,
            maxRecognizedCharacters: actualConfig.maxRecognizedCharacters
        )
        self.runtimeManager = runtimeManager
        self.configuration = actualConfig
    }

    /// Captures the frontmost window for the focused process, runs OCR, and summarizes the result
    /// into a short reusable context hint for prompt injection.
    func generateContext(
        for context: FocusedInputSnapshot,
        onStatusChange: (@Sendable (VisualContextStatus) async -> Void)? = nil
    ) async throws -> InjectedVisualContext {
        log(
            "context-start app=\(context.applicationName) pid=\(context.processIdentifier) element=\(context.elementIdentifier)"
        )
        await onStatusChange?(.capturing)

        let screenshot: CapturedWindowScreenshot
        do {
            screenshot = try await screenshotService.captureFrontmostWindow(processIdentifier: pid_t(context.processIdentifier))
        } catch let error as WindowScreenshotError {
            log("context-capture-failed reason=\(error.localizedDescription)")
            throw ScreenshotContextGenerationError.unavailable(error.localizedDescription)
        } catch {
            log("context-capture-failed reason=\(error.localizedDescription)")
            throw ScreenshotContextGenerationError.failed(error.localizedDescription)
        }

        log(
            "context-captured window=\(screenshot.windowTitle ?? "<untitled>") " +
                "image=\(screenshot.image.width)x\(screenshot.image.height)"
        )

        await onStatusChange?(.extractingText)

        let recognizedText: String
        do {
            recognizedText = try await textExtractor.extractText(from: screenshot.image).text
        } catch ScreenTextExtractionError.noRecognizedText {
            guard let windowTitle = screenshot.windowTitle,
                  hasMeaningfulSignal(windowTitle)
            else {
                log("context-ocr-unavailable no-recognized-text-and-weak-window-title")
                throw ScreenshotContextGenerationError.unavailable(
                    "The screenshot did not contain enough visible text to build prompt context."
                )
            }

            recognizedText = ""
            log("context-ocr-empty using-window-title-fallback")
        } catch let error as ScreenTextExtractionError {
            log("context-ocr-failed reason=\(error.localizedDescription)")
            throw ScreenshotContextGenerationError.unavailable(error.localizedDescription)
        } catch {
            log("context-ocr-failed reason=\(error.localizedDescription)")
            throw ScreenshotContextGenerationError.failed(error.localizedDescription)
        }

        log("context-ocr-ready chars=\(recognizedText.count)")

        let screenshotSignal = [screenshot.windowTitle, recognizedText]
            .compactMap { $0 }
            .joined(separator: "\n")

        guard hasMeaningfulSignal(screenshotSignal) else {
            log("context-unavailable weak-screenshot-signal")
            throw ScreenshotContextGenerationError.unavailable(
                "The screenshot did not contain enough visible text to build prompt context."
            )
        }

        let sourceText = buildSourceText(
            appName: context.applicationName,
            windowTitle: screenshot.windowTitle,
            recognizedText: recognizedText
        )

        let prompt = buildSummaryPrompt(recognizedText: sourceText)

        await onStatusChange?(.generatingSummary)

        let modelDescription = runtimeManager.diagnostics.modelFilePath.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? "<unknown-model>"
        log("context-summary-start model=\(modelDescription)")

        let rawSummary = try await runtimeManager.generate(
            prompt: prompt,
            maxPredictionTokens: configuration.maxSummaryTokens,
            temperature: configuration.temperature,
            topK: configuration.topK,
            topP: configuration.topP,
            minP: configuration.minP,
            repetitionPenalty: configuration.repetitionPenalty
        )

        let normalizedSummary = normalizeSummary(rawSummary)
        guard !normalizedSummary.isEmpty else {
            log("context-summary-empty model-returned-no-usable-text")
            throw ScreenshotContextGenerationError.failed("The local model returned an empty screenshot summary.")
        }

        log("context-summary-ready summary=\(preview(normalizedSummary))")

        return InjectedVisualContext(
            summary: normalizedSummary
        )
    }

    /// The OCR excerpt is intentionally compressed before it reaches the model. We want enough
    /// semantic signal to infer document context, not a giant dump of UI chrome.
    private func buildSourceText(
        appName: String,
        windowTitle: String?,
        recognizedText: String
    ) -> String {
        let cappedText = String(recognizedText.prefix(configuration.maxRecognizedCharacters))
        let sections = [
            "App: \(appName)",
            windowTitle.map { "Window title: \($0)" },
            "Visible text:\n\(cappedText)"
        ].compactMap { $0 }

        return sections.joined(separator: "\n\n")
    }

    /// We ask for exactly one short hint so prompt injection stays minimal and stable.
    private func buildSummaryPrompt(recognizedText: String) -> String {
        [
            "Extract exactly one short ScreenContextHint from the visible work context.",
            "Return only one word when possible (examples: Email, Messages, Notes, Discord).",
            "Do not return a sentence or a list.",
            recognizedText,
            "ScreenContextHint:"
        ].joined(separator: "\n\n")
    }

    /// Screenshot summaries should be compact and stable. We strip common instruction-model
    /// debris here so prompt injection does not inherit formatting noise.
    private func normalizeSummary(_ rawSummary: String) -> String {
        var normalized = rawSummary.replacingOccurrences(of: "\r", with: "")
        normalized = normalized
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`-:"))
            .replacingOccurrences(
                of: "^\\s*ScreenContextHints?\\s*:\\s*",
                with: "",
                options: .regularExpression
            )

        // Instruction-tuned models often prefix summaries with list markers like "1." or "-".
        // Strip those so injected context stays stylistically neutral for inline completion.
        normalized = normalized.replacingOccurrences(
            of: "^\\s*(?:\\d+[.)]|[-*•])\\s*",
            with: "",
            options: .regularExpression
        )

        normalized = normalized.replacingOccurrences(
            of: "(?m)^\\s*(?:\\d+[.)]|[-*•])\\s*",
            with: "",
            options: .regularExpression
        )

        normalized = normalized.replacingOccurrences(of: "\\n+", with: " ", options: .regularExpression)

        let firstSegment = normalized
            .components(separatedBy: CharacterSet(charactersIn: ",;|"))
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`-:.")))
            }
            .first { !$0.isEmpty } ?? ""

        let hintToken = firstSegment
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .first { hasUsefulSummarySignal($0) } ?? ""

        guard !hintToken.isEmpty else {
            return ""
        }

        let clampedHint = String(hintToken.prefix(24))
        let capitalizedHint = clampedHint.prefix(1).uppercased() + clampedHint.dropFirst()
        return capitalizedHint
    }

    /// We reject summaries that are mostly punctuation or numeric noise because those would hurt
    /// the completion prompt more than help it.
    private func hasMeaningfulSignal(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= configuration.minRecognizedCharacterCount else {
            return false
        }

        let letterCount = trimmed.unicodeScalars.filter(CharacterSet.letters.contains).count
        return letterCount >= 6
    }

    private func hasUsefulSummarySignal(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else {
            return false
        }

        let letterCount = trimmed.unicodeScalars.filter(CharacterSet.letters.contains).count
        return letterCount >= 3
    }

    private func log(_ message: String) {
        _ = message
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
