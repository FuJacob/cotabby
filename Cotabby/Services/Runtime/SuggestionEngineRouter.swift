import Foundation
import Logging

/// File overview:
/// Routes generation requests to the currently selected autocomplete engine.
/// This keeps engine selection in the composition/runtime layer instead of forcing
/// `SuggestionCoordinator` to know about concrete backend types.
@MainActor
final class SuggestionEngineRouter {
    private let suggestionSettings: SuggestionSettingsModel
    private let foundationModelEngine: any SuggestionGenerating
    private let llamaEngine: any SuggestionGenerating

    init(
        suggestionSettings: SuggestionSettingsModel,
        foundationModelEngine: any SuggestionGenerating,
        llamaEngine: any SuggestionGenerating
    ) {
        self.suggestionSettings = suggestionSettings
        self.foundationModelEngine = foundationModelEngine
        self.llamaEngine = llamaEngine
    }

    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        let metadata: Logger.Metadata = [
            "request_id": .string(request.requestID),
            "engine": .string(engineMetadataLabel(for: suggestionSettings.selectedEngine))
        ]
        switch suggestionSettings.selectedEngine {
        case .appleIntelligence:
            CotabbyLogger.suggestion.debug("Routing to Apple Intelligence engine", metadata: metadata)
            do {
                return try await foundationModelEngine.generateSuggestion(for: request)
            } catch SuggestionClientError.unsupportedLanguageOrLocale(let message) {
                CotabbyLogger.suggestion.info(
                    "Apple Intelligence unsupported for locale, falling back to open-source: \(message)",
                    metadata: metadata.merging([
                        "fallback_engine": .string("llama"),
                        "reason": .string(message)
                    ]) { _, new in new }
                )
                return try await generateOpenSourceFallback(
                    for: request,
                    appleFailureMessage: message
                )
            }
        case .llamaOpenSource:
            CotabbyLogger.suggestion.debug("Routing to open-source llama engine", metadata: metadata)
            return try await llamaEngine.generateSuggestion(for: request)
        }
    }

    private func engineMetadataLabel(for kind: SuggestionEngineKind) -> String {
        switch kind {
        case .appleIntelligence:
            return "apple_intelligence"
        case .llamaOpenSource:
            return "llama"
        }
    }

    /// Clears backend-local continuation state when the coordinator knows the editing context is
    /// no longer continuous. The router fans this out so switching engines cannot leave stale
    /// state behind.
    func resetCachedGenerationContext() async {
        await foundationModelEngine.resetCachedGenerationContext()
        await llamaEngine.resetCachedGenerationContext()
    }

    /// Forwards the warmup hook only to the currently selected engine. The inactive backend has
    /// no benefit from warming caches the user is not about to hit, and the FM path specifically
    /// allocates a session as a side effect, so we keep that work out of the llama-selected path.
    func prewarm(for request: SuggestionRequest) async {
        switch suggestionSettings.selectedEngine {
        case .appleIntelligence:
            await foundationModelEngine.prewarm(for: request)
        case .llamaOpenSource:
            await llamaEngine.prewarm(for: request)
        }
    }

    /// Apple Intelligence can reject a request after global availability reports success because
    /// language support is checked against the active request/locale. Falling back here keeps the
    /// coordinator backend-agnostic while giving local models a chance to handle that text.
    private func generateOpenSourceFallback(
        for request: SuggestionRequest,
        appleFailureMessage: String
    ) async throws -> SuggestionResult {
        do {
            return try await llamaEngine.generateSuggestion(for: request)
        } catch SuggestionClientError.cancelled {
            throw SuggestionClientError.cancelled
        } catch {
            throw SuggestionClientError.unavailable(
                "\(appleFailureMessage) Open Source fallback also failed: \(error.localizedDescription)"
            )
        }
    }
}

extension SuggestionEngineRouter: SuggestionGenerating {}

/// A tiny runtime boundary used when an engine is a product option but not available in the
/// current process. Keeping this as a `SuggestionGenerating` implementation lets app composition
/// pass the same router dependencies on macOS versions that cannot load Apple Intelligence APIs.
@MainActor
final class UnavailableSuggestionEngine: SuggestionGenerating {
    let message: String

    init(message: String) {
        self.message = message
    }

    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        CotabbyLogger.suggestion.warning("Engine unavailable: \(self.message)")
        throw SuggestionClientError.unavailable(message)
    }

    func resetCachedGenerationContext() async {}
}
