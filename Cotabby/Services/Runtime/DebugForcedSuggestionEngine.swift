import Foundation
import Logging

/// File overview:
/// Developer-only engine decorator that answers every request with a fixed completion instead of
/// running a model. Placement work needs a deterministic ghost: the same text, instantly, in every
/// field, so screenshots of the ghost and of the host's own text after acceptance can be compared
/// pixel for pixel. Active only under `-cotabby-debug` when the `cotabbyDebugForcedSuggestion`
/// default holds a non-empty string; otherwise every call passes straight through to the wrapped
/// engine, so release behavior is untouched.
///
/// The forced text still runs through `SuggestionTextNormalizer` so the seam rules (leading-space
/// handling, trailing-text deduplication) match what a real completion would get.
@MainActor
final class DebugForcedSuggestionEngine: SuggestionGenerating {
    static let defaultsKey = "cotabbyDebugForcedSuggestion"

    private let wrapped: any SuggestionGenerating
    private let userDefaults: UserDefaults

    init(wrapping wrapped: any SuggestionGenerating, userDefaults: UserDefaults = .standard) {
        self.wrapped = wrapped
        self.userDefaults = userDefaults
    }

    /// Whether the decorator should be installed at all: debug launch plus a configured string.
    static func isConfigured(userDefaults: UserDefaults = .standard) -> Bool {
        guard CotabbyDebugOptions.isEnabled else { return false }
        return !(userDefaults.string(forKey: defaultsKey) ?? "").isEmpty
    }

    private var forcedText: String? {
        guard CotabbyDebugOptions.isEnabled, let text = userDefaults.string(forKey: Self.defaultsKey), !text.isEmpty else {
            return nil
        }
        return text
    }

    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        try await generateSuggestion(for: request, onPartial: nil)
    }

    func generateSuggestion(
        for request: SuggestionRequest,
        onPartial: (@MainActor (SuggestionResult) -> Void)?
    ) async throws -> SuggestionResult {
        guard let forcedText else {
            return try await wrapped.generateSuggestion(for: request, onPartial: onPartial)
        }
        // A request anchored at a word boundary expects the model to re-emit the partial word before
        // continuing (see `WordBoundaryAnchorPolicy`); the forced text plays that model faithfully.
        let rawText = request.wordBoundaryAnchor.map { $0 + forcedText } ?? forcedText
        let normalization = SuggestionTextNormalizer.normalizeDetailed(rawText, for: request)
        CotabbyLogger.suggestion.debug(
            "Forced debug suggestion",
            metadata: ["request_id": .string(request.requestID), "engine": .string("debug_forced")]
        )
        return SuggestionResult(
            generation: request.generation,
            rawText: rawText,
            text: normalization.text,
            latency: 0.001,
            suppressionReason: normalization.suppression?.rawValue
        )
    }

    func resetCachedGenerationContext() async {
        await wrapped.resetCachedGenerationContext()
    }

    func prewarm(for request: SuggestionRequest) async {
        guard forcedText == nil else { return }
        await wrapped.prewarm(for: request)
    }
}
