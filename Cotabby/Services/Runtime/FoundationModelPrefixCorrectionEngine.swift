import Foundation
import Logging

#if canImport(FoundationModels)
import FoundationModels
#endif

/// File overview:
/// Adapts Apple's on-device Foundation Models framework to Cotabby's `PrefixCorrecting`
/// capability. The coordinator uses this to ask Apple Intelligence for a typo-fixed version
/// of the user's currently-typed prefix; the safety filter downstream decides whether the
/// returned text is conservative enough to apply.
///
/// Why Apple Intelligence only: prefix auto-correct demands tight instruction-following
/// (no rephrasing, no capitalization changes, no extra tokens). The bundled local llama
/// model isn't reliable at this task and would silently rewrite the user's prose. Routing
/// is deliberately one-engine for v1 — additional backends can adopt the protocol later.
#if canImport(FoundationModels)
@available(macOS 26.0, *)
@MainActor
final class FoundationModelPrefixCorrectionEngine {
    private let availabilityService: FoundationModelAvailabilityService

    init(availabilityService: FoundationModelAvailabilityService) {
        self.availabilityService = availabilityService
    }

    var isAvailable: Bool {
        availabilityService.refresh()
        return availabilityService.isAvailable
    }

    func proposeCorrection(for prefix: String) async throws -> String? {
        availabilityService.refresh()
        guard availabilityService.isAvailable else {
            let message = availabilityService.userVisibleMessage
            TabbyLogger.suggestion.debug("Prefix-correction unavailable: \(message)")
            return nil
        }
        guard let model = availabilityService.systemLanguageModel else {
            return nil
        }

        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrefix.isEmpty else { return nil }

        do {
            let startTime = Date()
            let session = LanguageModelSession(
                model: model,
                instructions: Self.correctionInstructions
            )
            // Deterministic decoding so the same prefix yields the same correction and the safety
            // filter can reason about the output shape predictably.
            let options = GenerationOptions(
                sampling: .greedy,
                temperature: 0.0,
                maximumResponseTokens: tokenBudget(for: prefix)
            )
            let response = try await session.respond(to: prefix, options: options)
            try Task.checkCancellation()

            let raw = response.content
            let cleaned = strippedResponse(raw)
            let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
            TabbyLogger.suggestion.debug(
                "Prefix-correction: in=\(prefix.count) chars, out=\(cleaned.count) chars, latency=\(latencyMs)ms"
            )
            return cleaned.isEmpty ? nil : cleaned
        } catch is CancellationError {
            throw SuggestionClientError.cancelled
        } catch let error as LanguageModelSession.GenerationError {
            TabbyLogger.suggestion.debug("Prefix-correction generation error: \(error.localizedDescription)")
            // Swallow into nil rather than throwing — a failed correction should be invisible to
            // the user, not surfaced as an autocomplete error.
            return nil
        } catch {
            TabbyLogger.suggestion.debug("Prefix-correction unexpected error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Prompting

    private static let correctionInstructions: String = """
    You correct spelling typos in text from an inline autocomplete tool.

    Rules — apply without exception:
    - Only fix obvious misspellings of individual words.
    - Never add, remove, reorder, or rephrase words.
    - Never change capitalization, punctuation, spacing, or line breaks.
    - Never add quotes, prefixes, suffixes, explanations, or commentary.
    - If there are no typos, return the input unchanged.

    Output only the corrected text.
    """

    /// Token budget sized to "input length plus a little slack" because typo-fixes do not grow
    /// the text appreciably. Anything longer is already suspicious and the safety filter will
    /// reject it, but a tighter budget also lets us cut off runaway generation.
    private func tokenBudget(for prefix: String) -> Int {
        // ~4 chars per token, generous upward rounding plus 16 tokens of slack.
        max(32, prefix.count / 3 + 16)
    }

    /// Models occasionally bracket their output in quotes or prepend "Corrected: ". The safety
    /// filter would reject those, but stripping the most common wrappers here makes the filter's
    /// real-world hit rate noticeably higher.
    private func strippedResponse(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let openQuote = text.first, openQuote == "\"" || openQuote == "“",
           let closeQuote = text.last, closeQuote == "\"" || closeQuote == "”",
           text.count >= 2 {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}

@available(macOS 26.0, *)
extension FoundationModelPrefixCorrectionEngine: PrefixCorrecting {}
#endif

/// Always-unavailable fallback used when the FoundationModels SDK is missing or the
/// host macOS is older than the supported Apple Intelligence release. The coordinator
/// gates on `isAvailable` before calling, so this drops every correction silently.
@MainActor
final class UnavailablePrefixCorrectionEngine: PrefixCorrecting {
    var isAvailable: Bool { false }
    func proposeCorrection(for prefix: String) async throws -> String? { nil }
}
