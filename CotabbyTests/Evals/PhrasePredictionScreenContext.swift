import Foundation
@testable import Cotabby

/// Bridges synthetic screen fixtures to the production OCR-to-request boundary. Owned by no
/// service and holding no state, this adapter is used by the live replay and model-free tests.
/// It deliberately stops short of capture/Vision: text quality is controlled so changes in
/// context use can be measured independently from recognition quality or window permissions.
@MainActor
enum PhrasePredictionScreenContext {
    static func request(
        checkpoint: PhrasePredictionScorer.Checkpoint,
        scenario: PhrasePredictionCorpus.ScreenScenario,
        condition: PhrasePredictionScorer.ContextCondition,
        settings: SuggestionSettingsSnapshot,
        configuration: SuggestionConfiguration,
        promptVariant: String = "production"
    ) -> SuggestionRequest {
        let context = CotabbyTestFixtures.focusedInputContext(
            applicationName: scenario.applicationName, bundleIdentifier: scenario.bundleIdentifier,
            precedingText: checkpoint.prefix, trailingText: "",
            windowTitle: scenario.windowTitle, fieldPlaceholder: scenario.fieldPlaceholder
        )
        let excerpt: String?
        if condition == .screen {
            // Fixed geometry models document/thread content above a composer. Include only the
            // already-typed draft as an OCR echo; the production selector must remove it. The
            // complete reference sentence is never available at this boundary.
            let sourceLines = scenario.screenText.components(separatedBy: .newlines)
            var lines = sourceLines.enumerated().map { index, text in
                OCRTextHygiene.OCRLine(text: text, confidence: 0.99,
                    boundingBox: CGRect(x: 0.12, y: max(0.3, 0.95 - Double(index) * 0.055), width: 0.78, height: 0.04))
            }
            lines += checkpoint.prefix.components(separatedBy: .newlines).map {
                OCRTextHygiene.OCRLine(text: $0, confidence: 0.99,
                    boundingBox: CGRect(x: 0.12, y: 0.12, width: 0.78, height: 0.04))
            }
            let visual = VisualContextConfiguration.forEngine(.llamaOpenSource)
            excerpt = VisualContextExcerptSelector.select(
                lines: lines, fieldText: checkpoint.prefix,
                focusBounds: CGRect(x: 0.12, y: 0.05, width: 0.78, height: 0.15),
                maxCharacters: visual.maxSummaryCharacters
            )
        } else {
            excerpt = nil
        }
        // Both conditions use identical field history and surface metadata. Only the visible
        // OCR excerpt differs; the factory still applies its sanitizer and prompt budgets.
        let request = SuggestionRequestFactory.buildRequest(
            context: context, settings: settings, configuration: configuration,
            visualContextSummary: excerpt
        ).request
        guard ["compact-surface", "compact-language"].contains(promptVariant) else { return request }
        // Keep rejected prompt experiments opt-in and outside app settings. Production uses
        // the factory unchanged; comparisons replace only the prompt representation.
        let languages = LanguageCatalog.normalize(settings.responseLanguages)
        let compactLanguage = languages.isEmpty ? nil : "Usual language: " + languages.joined(separator: ", ") + "."
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: request.prefixText, applicationName: context.applicationName,
            userName: request.userName, trailingText: context.trailingText,
            maxSuffixCharacters: request.maxSuffixCharacters, customRules: request.customRules,
            extendedContext: request.extendedContext,
            languageInstruction: promptVariant == "compact-language" ? compactLanguage : request.languageInstruction,
            clipboardContext: request.clipboardContext, visualContextSummary: request.visualContextSummary,
            surfaceContext: request.surfaceContext, usesCompactSurfaceContext: promptVariant == "compact-surface",
            tokenBudget: configuration.llamaPromptTokenBudget
        )
        return SuggestionRequest(
            context: request.context, prefixText: request.prefixText, prompt: prompt,
            generation: request.generation, maxPredictionTokens: request.maxPredictionTokens,
            temperature: request.temperature, topK: request.topK, topP: request.topP,
            minP: request.minP, repetitionPenalty: request.repetitionPenalty, randomSeed: request.randomSeed,
            maxSuffixCharacters: request.maxSuffixCharacters,
            completionLengthInstruction: request.completionLengthInstruction, userName: request.userName,
            customRules: request.customRules, extendedContext: request.extendedContext,
            languageInstruction: request.languageInstruction, clipboardContext: request.clipboardContext,
            visualContextSummary: request.visualContextSummary, surfaceContext: request.surfaceContext,
            isMultiLineEnabled: request.isMultiLineEnabled, requestID: request.requestID
        )
    }
}
