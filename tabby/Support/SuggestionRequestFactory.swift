import Foundation

/// File overview:
/// Owns the pure rules for deciding whether Tabby should generate and, when it should, how the
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

    /// Builds the generation request plus the exact prompt preview used by Tabby's diagnostics UI.
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
        let suffixText = truncatedPromptSuffix(
            from: context.trailingText,
            configuration: configuration
        )
        let completionLengthInstruction = settings.selectedWordCountPreset.promptInstruction
        let userName = activeUserName(settings: settings)
        let boundedClipboardContext = activeClipboardContext(
            rawContext: clipboardContext,
            settings: settings
        )
        let boundedFieldContext = activeFieldContext(rawContext: context.fieldContextText)
        let boundedVisualContextSummary = activeVisualContextSummary(
            rawSummary: visualContextSummary
        )
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: prefixText,
            suffixText: suffixText,
            applicationName: context.applicationName,
            completionLengthInstruction: completionLengthInstruction,
            userName: userName,
            clipboardContext: boundedClipboardContext,
            fieldContextText: boundedFieldContext,
            visualContextSummary: boundedVisualContextSummary
        )

        let request = SuggestionRequest(
            context: context,
            prefixText: prefixText,
            suffixText: suffixText,
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
            userName: userName,
            clipboardContext: boundedClipboardContext,
            fieldContextText: boundedFieldContext,
            visualContextSummary: boundedVisualContextSummary
        )

        return SuggestionRequestBuildResult(
            request: request,
            promptPreview: promptPreview(for: request, selectedEngine: settings.selectedEngine)
        )
    }

    /// Keep recent context while preserving the user's original spacing and line breaks.
    ///
    /// Older code split the prefix into words and joined them with single spaces. That was compact,
    /// but it erased paragraph/list/code shape, which is exactly the signal an autocomplete model uses
    /// to infer "what kind of thing is being written." We still bound by characters and words, but the
    /// final slice stays verbatim.
    private static func truncatedPromptPrefix(
        from precedingText: String,
        configuration: SuggestionConfiguration
    ) -> String {
        let characterWindow = String(precedingText.suffix(configuration.maxPrefixCharacters))
        return suffixPreservingWhitespace(
            from: characterWindow,
            maxWords: configuration.maxPrefixWords
        )
    }

    /// Keep only the beginning of the suffix after the caret.
    ///
    /// The suffix is not a second thing to complete; it is a constraint the generated text must fit
    /// before. A short bounded window is enough for the model to avoid duplicating or contradicting
    /// the text that is already after the insertion point.
    private static func truncatedPromptSuffix(
        from trailingText: String,
        configuration: SuggestionConfiguration
    ) -> String {
        String(trailingText.prefix(configuration.maxSuffixCharacters))
    }

    private static func suffixPreservingWhitespace(
        from text: String,
        maxWords: Int
    ) -> String {
        guard maxWords > 0 else {
            return text
        }

        var wordRanges: [Range<String.Index>] = []
        var wordStart: String.Index?
        var index = text.startIndex

        while index < text.endIndex {
            if text[index].isWhitespace {
                if let start = wordStart {
                    wordRanges.append(start..<index)
                    wordStart = nil
                }
            } else if wordStart == nil {
                wordStart = index
            }

            index = text.index(after: index)
        }

        if let start = wordStart {
            wordRanges.append(start..<text.endIndex)
        }

        guard wordRanges.count > maxWords,
              let firstKeptWordStart = wordRanges.suffix(maxWords).first?.lowerBound
        else {
            return text
        }

        return String(text[firstKeptWordStart...])
    }

    private static func activeUserName(
        settings: SuggestionSettingsSnapshot
    ) -> String? {
        settings.userName
    }

    private static func activeClipboardContext(
        rawContext: String?,
        settings: SuggestionSettingsSnapshot
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

        return clippedText(sanitizedContext, maxCharacters: maxClipboardContextCharacters)
    }

    private static func activeFieldContext(rawContext: String?) -> String? {
        guard let rawContext else {
            return nil
        }

        let sanitizedContext = PromptContextSanitizer.sanitize(rawContext, maxCharacters: 500)
        guard !sanitizedContext.isEmpty,
              PromptContextSanitizer.containsAlphanumericSignal(sanitizedContext)
        else {
            return nil
        }

        return sanitizedContext
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
        wordCountPreset: SuggestionWordCountPreset
    ) -> Int {
        max(configuration.maxPredictionTokens, wordCountPreset.suggestedPredictionTokenBudget)
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
