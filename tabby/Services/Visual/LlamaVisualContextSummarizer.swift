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
    private static let timeoutSeconds: UInt64 = 3
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

        let result = await summarizeWithTimeout(prompt: prompt)
        let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return truncateAtRepeatedBlock(trimmedResult)
    }

    /// Soft timeout: runs generation in a child Task and cancels it after the deadline.
    /// `LlamaRuntimeCore.summarize()` checks `Task.isCancelled` each token and returns whatever
    /// partial text it has accumulated, so the result is the best-effort summary — not a failure.
    private func summarizeWithTimeout(prompt: String) async -> String {
        let manager = runtimeManager

        let generationTask = Task {
            try await manager.summarize(
                prompt: prompt,
                maxPredictionTokens: 80,
                temperature: 0
            )
        }

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: Self.timeoutSeconds * 1_000_000_000)
            generationTask.cancel()
        }

        // Wait for generation to finish. On timeout, cancel fires → Task.isCancelled breaks
        // the token loop → core.summarize() returns partial text → task.value returns it.
        let result: String
        do {
            result = try await generationTask.value
        } catch {
            // Real error (model not loaded, etc.) — no partial text available.
            result = ""
        }
        timeoutTask.cancel()

        return result
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
    ///
    /// Uses a sliding window: for every starting position, checks whether a block of `blockSize`
    /// lines repeats immediately after itself. When found, everything from the second copy onward
    /// is dropped. Both paths return from the same normalized (trimmed, non-empty) line array so
    /// callers always get consistent formatting.
    private func truncateAtRepeatedBlock(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 4 else { return lines.joined(separator: "\n") }

        for i in 0 ..< lines.count {
            let maxBlockSize = (lines.count - i) / 2
            guard maxBlockSize >= 1 else { continue }
            for blockSize in 1 ... maxBlockSize {
                let repeatStart = i + blockSize
                let repeatEnd = repeatStart + blockSize
                guard repeatEnd <= lines.count else { continue }
                if Array(lines[i ..< repeatStart]) == Array(lines[repeatStart ..< repeatEnd]) {
                    return Array(lines[0 ..< repeatStart]).joined(separator: "\n")
                }
            }
        }

        return lines.joined(separator: "\n")
    }
}
