import Foundation

struct ComposeRequestBuildResult: Equatable, Sendable {
    let request: ComposeRequest
    let promptPreview: String
}

/// Builds the engine-facing request for Compose Mode.
///
/// This stays separate from `SuggestionRequestFactory` because Compose keeps broader context,
/// larger token budgets, and paragraph-preserving prompt rules.
enum ComposeRequestFactory {
    private static let maxTypedPrefixCharacters = 4_000
    private static let maxTrailingTextCharacters = 1_000
    private static let maxClipboardContextCharacters = 1_200
    private static let maxSurroundingContextCharacters = 8_000

    static func buildRequest(
        context: FocusedInputContext,
        settings: SuggestionSettingsSnapshot,
        configuration: SuggestionConfiguration,
        surroundingContext: String,
        clipboardContext: String?,
        visualContextSummary: String? = nil
    ) -> ComposeRequestBuildResult {
        let request = ComposeRequest(
            context: context,
            typedPrefix: clippedText(context.precedingText, maxCharacters: maxTypedPrefixCharacters),
            trailingText: clippedText(context.trailingText, maxCharacters: maxTrailingTextCharacters),
            surroundingContext: clippedText(surroundingContext, maxCharacters: maxSurroundingContextCharacters),
            visualContextSummary: activeOptionalContext(visualContextSummary, maxCharacters: maxSurroundingContextCharacters),
            clipboardContext: activeClipboardContext(rawContext: clipboardContext, settings: settings),
            applicationName: context.applicationName,
            generation: context.generation,
            maxPredictionTokens: max(256, configuration.maxPredictionTokens),
            temperature: max(0.35, configuration.temperature),
            topK: max(40, configuration.topK),
            topP: max(0.9, configuration.topP),
            minP: min(configuration.minP, 0.05),
            repetitionPenalty: max(1.08, configuration.repetitionPenalty),
            randomSeed: configuration.randomSeed,
            userName: activeUserName(settings: settings),
            userTags: activeUserTags(settings: settings)
        )
        let prompt = ComposePromptRenderer.prompt(for: request)

        return ComposeRequestBuildResult(
            request: request,
            promptPreview: prompt
        )
    }

    private static func activeUserName(settings: SuggestionSettingsSnapshot) -> String? {
        let trimmed = settings.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func activeUserTags(settings: SuggestionSettingsSnapshot) -> [String]? {
        let tags = settings.userTags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return tags.isEmpty ? nil : tags
    }

    private static func activeClipboardContext(
        rawContext: String?,
        settings: SuggestionSettingsSnapshot
    ) -> String? {
        guard settings.isClipboardContextEnabled else {
            return nil
        }

        return activeOptionalContext(rawContext, maxCharacters: maxClipboardContextCharacters)
    }

    private static func activeOptionalContext(
        _ rawContext: String?,
        maxCharacters: Int
    ) -> String? {
        guard let rawContext else {
            return nil
        }

        let trimmed = rawContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        return clippedText(trimmed, maxCharacters: maxCharacters)
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
}
