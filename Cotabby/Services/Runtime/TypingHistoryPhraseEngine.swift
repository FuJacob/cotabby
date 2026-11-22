import Foundation
import Logging

/// Answers a request straight from typing history when history knows how the phrase ends, and
/// otherwise hands it to the real engine.
///
/// Why a wrapper around the router: a phrase shortcut is just another way to produce a
/// `SuggestionResult`, so the coordinator, overlay, and acceptance code need no changes to use it.
/// Sitting in front of `SuggestionEngineRouter` also means one check covers every engine, and the
/// live engine kind is read at request time so the endpoint never gets history-derived text.
///
/// Lifetime: built once in `CotabbyAppEnvironment` around the router and owned by the coordinator
/// as its `suggestionEngine`.
@MainActor
final class TypingHistoryPhraseEngine: SuggestionGenerating {
    private let base: any SuggestionGenerating
    private let history: any SuggestionHistoryProviding
    private let engineKind: @MainActor () -> SuggestionEngineKind

    init(
        wrapping base: any SuggestionGenerating,
        history: any SuggestionHistoryProviding,
        engineKind: @escaping @MainActor () -> SuggestionEngineKind
    ) {
        self.base = base
        self.history = history
        self.engineKind = engineKind
    }

    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        try await generateSuggestion(for: request, onPartial: nil)
    }

    func generateSuggestion(
        for request: SuggestionRequest,
        onPartial: (@MainActor (SuggestionResult) -> Void)?
    ) async throws -> SuggestionResult {
        let started = ProcessInfo.processInfo.systemUptime
        if let phrase = history.phraseContinuation(for: request, engine: engineKind()) {
            CotabbyLogger.suggestion.debug(
                "Answered from typing history",
                metadata: ["request_id": .string(request.requestID), "engine": .string("history")]
            )
            // The phrase is the user's own text, character for character, including the leading
            // space, so the ghost renders it exactly instead of re-deciding the word boundary.
            return SuggestionResult(
                generation: request.generation,
                rawText: phrase,
                text: phrase,
                latency: ProcessInfo.processInfo.systemUptime - started,
                spacingIsExact: true
            )
        }
        return try await base.generateSuggestion(for: request, onPartial: onPartial)
    }

    func resetCachedGenerationContext() async {
        await base.resetCachedGenerationContext()
    }

    func prewarm(for request: SuggestionRequest) async {
        await base.prewarm(for: request)
    }
}
