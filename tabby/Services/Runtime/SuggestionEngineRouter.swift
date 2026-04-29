import Foundation

/// File overview:
/// Routes generation requests to the currently selected autocomplete engine.
/// This keeps engine selection in the composition/runtime layer instead of forcing
/// `SuggestionCoordinator` to know about concrete backend types.
@MainActor
final class SuggestionEngineRouter {
    private let suggestionSettings: SuggestionSettingsModel
    private let foundationModelEngine: FoundationModelSuggestionEngine
    private let llamaEngine: LlamaSuggestionEngine

    init(
        suggestionSettings: SuggestionSettingsModel,
        foundationModelEngine: FoundationModelSuggestionEngine,
        llamaEngine: LlamaSuggestionEngine
    ) {
        self.suggestionSettings = suggestionSettings
        self.foundationModelEngine = foundationModelEngine
        self.llamaEngine = llamaEngine
    }

    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        switch suggestionSettings.selectedEngine {
        case .appleIntelligence:
            return try await foundationModelEngine.generateSuggestion(for: request)
        case .llamaOpenSource:
            return try await llamaEngine.generateSuggestion(for: request)
        }
    }

    /// Clears backend-local continuation state when the coordinator knows the editing context is
    /// no longer continuous. The router fans this out so switching engines cannot leave stale
    /// llama KV state behind.
    func resetCachedGenerationContext() async {
        await foundationModelEngine.resetCachedGenerationContext()
        await llamaEngine.resetCachedGenerationContext()
    }
}

extension SuggestionEngineRouter: SuggestionGenerating {}
