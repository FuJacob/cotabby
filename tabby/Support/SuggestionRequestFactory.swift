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
    /// Require completed word boundaries so prompts do not include half-typed trailing tokens.
    static func shouldGenerateSuggestion(for precedingText: String) -> Bool {
        let trimmed = precedingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        guard let trailingScalar = precedingText.unicodeScalars.last else {
            return false
        }

        return CharacterSet.whitespaces.contains(trailingScalar)
    }

    /// Builds the generation request plus the exact prompt preview used by Tabby's diagnostics UI.
    static func buildRequest(
        context: FocusedInputContext,
        promptMode: SuggestionPromptMode,
        wordCountPreset: SuggestionWordCountPreset,
        configuration: SuggestionConfiguration,
        injectedContextSummary: String?
    ) -> SuggestionRequestBuildResult {
        let prompt = buildPrompt(
            from: context,
            promptMode: promptMode,
            wordCountPreset: wordCountPreset,
            configuration: configuration,
            injectedContextSummary: injectedContextSummary
        )

        let request = SuggestionRequest(
            context: context,
            prompt: prompt,
            // Preserve the raw summary on the engine request so logs and downstream consumers can
            // inspect the exact injected value; prompt rendering applies its own normalization.
            injectedContextSummary: injectedContextSummary,
            generation: context.generation,
            maxPredictionTokens: activeMaxPredictionTokens(
                configuration: configuration,
                wordCountPreset: wordCountPreset
            ),
            temperature: configuration.temperature,
            topK: configuration.topK,
            topP: configuration.topP,
            minP: configuration.minP,
            repetitionPenalty: configuration.repetitionPenalty,
            maxSuffixCharacters: configuration.maxSuffixCharacters,
            customAIInstructions: activeCompletionInstruction(
                configuration: configuration,
                wordCountPreset: wordCountPreset
            )
        )

        return SuggestionRequestBuildResult(
            request: request,
            promptPreview: prompt
        )
    }

    /// Builds the prompt contract that the local model sees for the current focused field.
    private static func buildPrompt(
        from context: FocusedInputContext,
        promptMode: SuggestionPromptMode,
        wordCountPreset: SuggestionWordCountPreset,
        configuration: SuggestionConfiguration,
        injectedContextSummary: String?
    ) -> String {
        let prefix = truncatedPromptPrefix(
            from: context.precedingText,
            configuration: configuration
        )

        if promptMode == .prefixOnly {
            // Prefix-only mode intentionally sends just the user's trailing text context.
            // It is the lowest-latency path and avoids instruction-tuned prompt overhead.
            return prefix
        }

        var sections = [
            "You are an inline autocomplete engine for one text field.",
            "",
            "Rules (highest priority):",
            "Return exactly one continuation fragment.",
            wordCountPreset.promptInstruction,
            "Continue only from Prefix.",
            "Do not repeat Prefix text.",
            "ScreenContextHints are background hints only; never restate or continue them.",
            "No numbering, no bullets, no labels, no quotes, no markdown, no newline.",
            "Output plain text only."
        ]

        if let screenContextHints = normalizedScreenContextHints(from: injectedContextSummary) {
            sections.append("ScreenContextHints: \(screenContextHints)")
        }

        sections.append("Prefix: \(prefix)")
        sections.append("Continuation:")
        return sections.joined(separator: "\n")
    }

    /// Screen context should be metadata, not prose continuation, so we normalize it into one line.
    private static func normalizedScreenContextHints(from summary: String?) -> String? {
        guard let summary else {
            return nil
        }

        var normalized = summary
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\r", with: "")
            .replacingOccurrences(of: "\\n+", with: ", ", options: .regularExpression)
            .replacingOccurrences(
                of: "^\\s*ScreenContextHints?\\s*:\\s*",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: "\\s+,", with: ",", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;:")))

        if normalized.count > 160 {
            normalized = String(normalized.prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return normalized.isEmpty ? nil : normalized
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

    private static func activeCompletionInstruction(
        configuration: SuggestionConfiguration,
        wordCountPreset: SuggestionWordCountPreset
    ) -> String {
        [configuration.customAIInstructions, wordCountPreset.promptInstruction]
            .joined(separator: " ")
    }

    private static func activeMaxPredictionTokens(
        configuration: SuggestionConfiguration,
        wordCountPreset: SuggestionWordCountPreset
    ) -> Int {
        max(configuration.maxPredictionTokens, wordCountPreset.suggestedPredictionTokenBudget)
    }
}
