import Foundation
import Logging

/// Converts OCR text into a compact prompt-safe visual context summary.
///
/// The protocol keeps `ScreenshotContextGenerator` independent from the concrete llama runtime.
/// That boundary matters because capture/OCR can be tested or reused without forcing a local model
/// call in every environment.
protocol VisualContextSummarizing: AnyObject, Sendable {
    func summarize(text: String, applicationName: String) async throws -> String
}

enum VisualContextSummarizationError: LocalizedError {
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .emptyResult:
            return "Visual context summarization produced no usable text."
        }
    }
}

/// Local-model implementation of visual-context summarization.
///
/// This type owns only the summarization prompt. Screenshot capture, OCR, prompt-injection limits,
/// and stale-session checks remain in their own services so model prompting does not become a
/// hidden owner of the visual-context lifecycle.
@MainActor
final class LlamaVisualContextSummarizer: VisualContextSummarizing {
    private static let timeoutSeconds: UInt64 = 6
    private let runtimeManager: LlamaRuntimeManager

    init(runtimeManager: LlamaRuntimeManager) {
        self.runtimeManager = runtimeManager
    }

    func summarize(text: String, applicationName: String) async throws -> String {
        CotabbyLogger.app.debug("Summarizing visual context for \(applicationName): \(text.count) chars input")
        // Deduplicate repeated lines before sending to the model. OCR from screens showing
        // chatbot output (e.g. "Final Answer\nFinal Answer\n...") teaches the model to loop
        // that pattern verbatim in its output. Collapsing consecutive duplicates removes the
        // repeating signal without losing any unique content.
        let deduplicatedText = deduplicateConsecutiveLines(text)

        let prompt = VisualContextSummaryPromptRenderer.prompt(
            applicationName: applicationName,
            screenText: deduplicatedText
        )

        let result = try await summarizeWithTimeout(prompt: prompt)
        let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedResult = truncateAtRepeatedBlock(trimmedResult)
        guard !cleanedResult.isEmpty else {
            throw VisualContextSummarizationError.emptyResult
        }

        return cleanedResult
    }

    /// Soft timeout: runs generation in a child Task and cancels it after the deadline.
    /// `LlamaRuntimeCore.summarize()` checks `Task.isCancelled` each token and returns whatever
    /// partial text it has accumulated, so the result is the best-effort summary — not a failure.
    private func summarizeWithTimeout(prompt: String) async throws -> String {
        let manager = runtimeManager

        let generationTask = Task {
            try await manager.summarize(
                prompt: prompt,
                maxPredictionTokens: 160,
                temperature: 0
            )
        }

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: Self.timeoutSeconds * 1_000_000_000)
            generationTask.cancel()
        }

        defer { timeoutTask.cancel() }

        // Wait for generation to finish. On timeout, cancellation either returns a partial summary
        // from the runtime or throws; both paths are useful because the caller can fall back to OCR.
        let result = try await generationTask.value
        if result.isEmpty {
            CotabbyLogger.app.debug("Summarization produced empty result")
        } else {
            CotabbyLogger.app.debug("Summarization produced \(result.count) chars")
        }

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

        for lineIndex in 0 ..< lines.count {
            let maxBlockSize = (lines.count - lineIndex) / 2
            guard maxBlockSize >= 1 else { continue }
            for blockSize in 1 ... maxBlockSize {
                let repeatStart = lineIndex + blockSize
                let repeatEnd = repeatStart + blockSize
                guard repeatEnd <= lines.count else { continue }
                if Array(lines[lineIndex ..< repeatStart]) == Array(lines[repeatStart ..< repeatEnd]) {
                    return Array(lines[0 ..< repeatStart]).joined(separator: "\n")
                }
            }
        }

        return lines.joined(separator: "\n")
    }
}
