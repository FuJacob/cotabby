import Foundation

/// File overview:
/// Owns the pure rules for deciding whether Cotabby should generate and, when it should, how the
/// request payload and backend-specific prompt preview are constructed.
/// This keeps prompt policy out of the coordinator.
///
/// Architectural role:
/// `SuggestionCoordinator` decides when a generation attempt should happen. This factory decides
/// what the request should contain once that decision has already been made.
struct SuggestionRequestBuildResult: Equatable, Sendable {
    /// The engine-facing request plus the selected backend's prompt preview shown in diagnostics.
    /// Keeping these together prevents preview text from drifting away from the chosen engine.
    let request: SuggestionRequest
    let promptPreview: String
}

/// Pure prompt-policy surface for the autocomplete pipeline.
/// This type has no access to UserDefaults, tasks, overlays, or runtime services.
enum SuggestionRequestFactory {
    private static let maxClipboardContextCharacters = 1_200

    /// Require at least one non-whitespace character so we don't suggest on a blank field.
    /// No trailing-space gate — the debounce handles rapid keystroke settling, and
    /// `SuggestionTextNormalizer` applies deterministic space management on the output side.
    static func shouldGenerateSuggestion(for precedingText: String) -> Bool {
        let trimmed = precedingText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
    }

    /// Builds the generation request plus the exact prompt preview used by Cotabby's diagnostics UI.
    static func buildRequest(
        context: FocusedInputContext,
        settings: SuggestionSettingsSnapshot,
        configuration: SuggestionConfiguration,
        clipboardContext: String? = nil,
        visualContextSummary: String? = nil
    ) -> SuggestionRequestBuildResult {
        let prefixText = truncatedPromptPrefix(
            from: context.precedingText,
            configuration: configuration
        )
        let completionLengthInstruction = settings.selectedWordCountPreset.promptInstruction
        let userName = activeUserName(settings: settings)
        let boundedClipboardContext = activeClipboardContext(
            rawContext: clipboardContext,
            settings: settings,
            prefixText: prefixText
        )
        let boundedVisualContextSummary = activeVisualContextSummary(
            rawSummary: visualContextSummary
        )
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: prefixText,
            applicationName: context.applicationName,
            completionLengthInstruction: completionLengthInstruction,
            userName: userName,
            clipboardContext: boundedClipboardContext,
            visualContextSummary: boundedVisualContextSummary
        )

        let request = SuggestionRequest(
            context: context,
            prefixText: prefixText,
            prompt: prompt,
            generation: context.generation,
            maxPredictionTokens: activeMaxPredictionTokens(
                configuration: configuration,
                wordCountPreset: settings.selectedWordCountPreset,
                isMultiLineEnabled: settings.isMultiLineEnabled
            ),
            temperature: configuration.temperature,
            topK: configuration.topK,
            topP: configuration.topP,
            minP: configuration.minP,
            repetitionPenalty: configuration.repetitionPenalty,
            randomSeed: configuration.randomSeed,
            maxSuffixCharacters: configuration.maxSuffixCharacters,
            completionLengthInstruction: completionLengthInstruction,
            userName: userName,
            clipboardContext: boundedClipboardContext,
            visualContextSummary: boundedVisualContextSummary,
            isMultiLineEnabled: settings.isMultiLineEnabled
        )

        return SuggestionRequestBuildResult(
            request: request,
            promptPreview: promptPreview(for: request, selectedEngine: settings.selectedEngine)
        )
    }

    /// Keep only the latest short word tail to prevent long stale context from steering output.
    ///
    /// Exposed (non-private) so the coordinator can compute the same bounded window before
    /// calling the relevance filter, ensuring the filter and the downstream distiller evaluate
    /// token overlap against an identical prefix.
    static func truncatedPromptPrefix(
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

    private static func activeUserName(
        settings: SuggestionSettingsSnapshot
    ) -> String? {
        settings.userName
    }

    private static func activeClipboardContext(
        rawContext: String?,
        settings: SuggestionSettingsSnapshot,
        prefixText: String
    ) -> String? {
        guard settings.isClipboardContextEnabled,
              let rawContext
        else {
            return nil
        }

        let sanitizedContext = PromptContextSanitizer.sanitize(rawContext)
        guard !sanitizedContext.isEmpty,
              PromptContextSanitizer.containsAlphanumericSignal(sanitizedContext)
        else {
            return nil
        }

        let distilled = ClipboardContentDistiller.distill(
            clipboard: sanitizedContext,
            prefixText: prefixText
        )
        return clippedText(distilled, maxCharacters: maxClipboardContextCharacters)
    }

    private static func activeVisualContextSummary(rawSummary: String?) -> String? {
        guard let rawSummary else {
            return nil
        }

        let sanitizedSummary = PromptContextSanitizer.sanitize(rawSummary)
        guard !sanitizedSummary.isEmpty,
              PromptContextSanitizer.containsAlphanumericSignal(sanitizedSummary)
        else {
            return nil
        }

        return sanitizedSummary
    }

    private static func clippedText(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else {
            return text
        }

        let suffix = "..."
        let allowedPrefixCount = max(maxCharacters - suffix.count, 0)
        return String(text.prefix(allowedPrefixCount))
            .trimmingCharacters(in: .whitespacesAndNewlines) + suffix
    }

    private static func activeMaxPredictionTokens(
        configuration: SuggestionConfiguration,
        wordCountPreset: SuggestionWordCountPreset,
        isMultiLineEnabled: Bool
    ) -> Int {
        let base = max(configuration.maxPredictionTokens, wordCountPreset.suggestedPredictionTokenBudget)
        return isMultiLineEnabled ? min(base * 2, 60) : base
    }

    private static func promptPreview(
        for request: SuggestionRequest,
        selectedEngine: SuggestionEngineKind
    ) -> String {
        switch selectedEngine {
        case .appleIntelligence:
            return FoundationModelPromptRenderer.promptPreview(for: request)
        case .llamaOpenSource:
            return request.prompt
        }
    }
}
