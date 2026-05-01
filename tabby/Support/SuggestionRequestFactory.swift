import Foundation

/// File overview:
/// Owns the pure rules for deciding whether Tabby should generate and, when it should, how the
/// request payload and prompt preview are constructed. This keeps prompt policy out of the coordinator.
///
/// Architectural role:
/// `SuggestionCoordinator` decides when a generation attempt should happen. This factory decides
/// what the request should contain once that decision has already been made.
struct SuggestionRequestBuildResult: Equatable, Sendable {
    /// The engine-facing request plus the exact prompt preview shown in the menu UI.
    /// Keeping these together prevents preview text from drifting away from the real request.
    let request: SuggestionRequest
    let promptPreview: String
}

/// Pure prompt-policy surface for the autocomplete pipeline.
/// This type has no access to UserDefaults, tasks, overlays, or runtime services.
enum SuggestionRequestFactory {
    /// Require at least one non-whitespace character so we don't suggest on a blank field.
    /// No trailing-space gate — the debounce handles rapid keystroke settling, and
    /// `SuggestionTextNormalizer` applies deterministic space management on the output side.
    static func shouldGenerateSuggestion(for precedingText: String) -> Bool {
        let trimmed = precedingText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
    }

    /// Builds the generation request plus the exact prompt preview used by Tabby's diagnostics UI.
    static func buildRequest(
        context: FocusedInputContext,
        settings: SuggestionSettingsSnapshot,
        configuration: SuggestionConfiguration
    ) -> SuggestionRequestBuildResult {
        let prefixText = truncatedPromptPrefix(
            from: context.precedingText,
            configuration: configuration
        )
        let completionLengthInstruction = settings.selectedWordCountPreset.promptInstruction
        let customAIInstructions = activeCustomAIInstructions(settings: settings)
        let prompt = buildPrompt(
            context: context,
            prefixText: prefixText,
            promptMode: settings.effectivePromptMode,
            completionLengthInstruction: completionLengthInstruction,
            customAIInstructions: customAIInstructions
        )

        let request = SuggestionRequest(
            context: context,
            prefixText: prefixText,
            prompt: prompt,
            generation: context.generation,
            maxPredictionTokens: activeMaxPredictionTokens(
                configuration: configuration,
                wordCountPreset: settings.selectedWordCountPreset
            ),
            temperature: configuration.temperature,
            topK: configuration.topK,
            topP: configuration.topP,
            minP: configuration.minP,
            repetitionPenalty: configuration.repetitionPenalty,
            randomSeed: configuration.randomSeed,
            maxSuffixCharacters: configuration.maxSuffixCharacters,
            completionLengthInstruction: completionLengthInstruction,
            customAIInstructions: customAIInstructions,
            isFirstTokenGatingEnabled: settings.isFirstTokenGatingEnabled,
            isFirstTokenConfidenceGatingEnabled: settings.isFirstTokenConfidenceGatingEnabled,
            firstTokenConfidenceThreshold: settings.firstTokenConfidenceThreshold
        )

        return SuggestionRequestBuildResult(
            request: request,
            promptPreview: prompt
        )
    }

    /// Builds the prompt contract that the local model sees for the current focused field.
    private static func buildPrompt(
        context: FocusedInputContext,
        prefixText: String,
        promptMode: SuggestionPromptMode,
        completionLengthInstruction: String,
        customAIInstructions: String?
    ) -> String {
        LlamaPromptRenderer.prompt(
            prefixText: prefixText,
            applicationName: context.applicationName,
            promptMode: promptMode,
            completionLengthInstruction: completionLengthInstruction,
            customAIInstructions: customAIInstructions
        )
    }

    /// Keep only the latest short word tail to prevent long stale context from steering output.
    private static func truncatedPromptPrefix(
        from precedingText: String,
        configuration: SuggestionConfiguration
    ) -> String {
        let characterWindow = String(precedingText.suffix(configuration.maxPrefixCharacters))
        let trailingWords = characterWindow
            .split(whereSeparator: { $0.isWhitespace })
            .suffix(configuration.maxPrefixWords)
            .map(String.init)
            .joined(separator: " ")

        return trailingWords.isEmpty ? characterWindow : trailingWords
    }

    private static func activeCustomAIInstructions(
        settings: SuggestionSettingsSnapshot
    ) -> String? {
        guard settings.effectivePromptMode == .guided else {
            return nil
        }

        return settings.customAIInstructions
    }

    private static func activeMaxPredictionTokens(
        configuration: SuggestionConfiguration,
        wordCountPreset: SuggestionWordCountPreset
    ) -> Int {
        max(configuration.maxPredictionTokens, wordCountPreset.suggestedPredictionTokenBudget)
    }
}
