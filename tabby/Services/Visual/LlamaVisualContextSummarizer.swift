import Foundation

/// Converts OCR text into a compact prompt-safe visual context summary.
///
/// The protocol keeps `ScreenshotContextGenerator` independent from the concrete llama runtime.
/// That boundary matters because capture/OCR can be tested or reused without forcing a local model
/// call in every environment.
protocol VisualContextSummarizing: AnyObject, Sendable {
    func summarize(text: String, applicationName: String) async throws -> String
}

/// Local-model implementation of visual-context summarization.
///
/// This type owns only the summarization prompt. Screenshot capture, OCR, prompt-injection limits,
/// and stale-session checks remain in their own services so model prompting does not become a
/// hidden owner of the visual-context lifecycle.
@MainActor
final class LlamaVisualContextSummarizer: VisualContextSummarizing {
    private let runtimeManager: LlamaRuntimeManager

    init(runtimeManager: LlamaRuntimeManager) {
        self.runtimeManager = runtimeManager
    }

    func summarize(text: String, applicationName: String) async throws -> String {
        let prompt = [
            "Task: Write a concise, 4-sentence summary of what the provided text from the application '\(applicationName)' is about.",
            "",
            "Rules:",
            "1. Output exactly and ONLY the summary text.",
            "2. DO NOT add conversational filler (e.g., 'Here is the summary').",
            "3. DO NOT add extra instructions or meta-commentary.",
            "4. DO NOT repeat the prompt.",
            "",
            "--- START SCREEN TEXT ---",
            text,
            "--- END SCREEN TEXT ---",
            "",
            "Summary:"
        ].joined(separator: "\n")

        let result = try await runtimeManager.summarize(
            prompt: prompt,
            maxPredictionTokens: 160,
            temperature: 0
        )
        let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedResult
    }
}
