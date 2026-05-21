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
        // Deduplicate repeated lines before sending to the model. OCR from screens showing
        // chatbot output (e.g. "Final Answer\nFinal Answer\n...") teaches the model to loop
        // that pattern verbatim in its output. Collapsing consecutive duplicates removes the
        // repeating signal without losing any unique content.
        let deduplicatedText = deduplicateConsecutiveLines(text)

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
            deduplicatedText,
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
        return truncateAtRepeatedBlock(trimmedResult)
    }

    /// Collapses runs of identical trimmed lines to a single occurrence.
    /// Preserves blank lines and non-duplicate content unchanged.
    private func deduplicateConsecutiveLines(_ text: String) -> String {
        var result: [String] = []
        var previous: String?
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed != previous {
                result.append(line)
                if !trimmed.isEmpty {
                    previous = trimmed
                }
            }
        }
        return result.joined(separator: "\n")
    }

    /// Detects repeated multi-line blocks in the model output and truncates at the first repeat.
    /// Small models under greedy decoding can still loop even with a full-window repetition penalty
    /// if the cycle length is long enough. This catches any remaining loops post-generation.
    private func truncateAtRepeatedBlock(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 4 else { return text }

        // Try block sizes from 1 line up to half the output.
        for blockSize in 1 ... lines.count / 2 {
            let block = Array(lines[0 ..< blockSize])
            let nextStart = blockSize
            let nextEnd = nextStart + blockSize
            guard nextEnd <= lines.count else { continue }
            let nextBlock = Array(lines[nextStart ..< nextEnd])
            if block == nextBlock {
                // Keep only the first occurrence of the block.
                return block.joined(separator: "\n")
            }
        }

        return text
    }
}
