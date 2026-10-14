import Foundation
import Logging
#if canImport(FoundationModels)
import FoundationModels
#endif

/// File overview:
/// Writes the draft of an answer from facts memory found, with an on-device model.
///
/// Which model: Apple Intelligence when it is available, since it follows instructions and can say
/// "the facts do not answer this" (`AnswerPromptRenderer.abstainMarker`); otherwise the selected
/// local llama model with the base-model transcript prompt. Never the OpenAI-compatible endpoint,
/// whatever engine autocomplete uses: an answer's facts come from memory, which never leaves the Mac.
///
/// The local model is shared with autocomplete (same runtime and lock), so a draft waits for an
/// in-flight suggestion and vice versa, and the next suggestion decodes its own prompt again,
/// because the runtime reuses a cached prefix only while its tokens still match. Drafts are rare
/// (one per question), so this is the accepted cost. Owned by `AnswerCoordinator`.
@MainActor
final class AnswerDraftEngine {
    struct Draft: Equatable, Sendable {
        let text: String
        /// "apple" or "llama", for the log.
        let engine: String
    }

    private let runtimeManager: LlamaRuntimeManager
    private let hasLocalModel: @MainActor () -> Bool
    private let availability: FoundationModelAvailabilityService

    init(runtimeManager: LlamaRuntimeManager, hasLocalModel: @escaping @MainActor () -> Bool,
         availability: FoundationModelAvailabilityService) {
        self.runtimeManager = runtimeManager
        self.hasLocalModel = hasLocalModel
        self.availability = availability
    }

    /// See `SuggestionQualityMetricsStore`: a stored-property main-actor class releases through a
    /// nonisolated deinit, avoiding the isolated-deinit runtime path.
    nonisolated deinit {}

    /// Whether any on-device model can draft right now.
    var canDraft: Bool { isAppleAvailable || hasLocalModel() }

    private var isAppleAvailable: Bool {
        if #available(macOS 26.0, *) {
            #if canImport(FoundationModels)
            return availability.isAvailable && availability.systemLanguageModel != nil
            #endif
        }
        return false
    }

    /// Which model drafts.
    nonisolated enum Drafter: Equatable, Sendable {
        case apple
        case local
    }

    /// Apple Intelligence whenever it is available, and then only it: when it abstains ("the facts
    /// do not answer this"), that is the answer, and the weaker local model never drafts anyway. The
    /// local model drafts only when Apple Intelligence is not available.
    nonisolated static func drafter(appleAvailable: Bool, hasLocalModel: Bool) -> Drafter? {
        if appleAvailable { return .apple }
        return hasLocalModel ? .local : nil
    }

    /// The draft, or nil when the model abstained or produced nothing usable.
    func draft(question: String, asker: String?, facts: [AnswerPromptRenderer.Fact]) async throws -> Draft? {
        switch Self.drafter(appleAvailable: isAppleAvailable, hasLocalModel: hasLocalModel()) {
        case .apple:
            return try await draftWithApple(question: question, asker: asker, facts: facts).map { Draft(text: $0, engine: "apple") }
        case .local:
            return try await Self.draftLocally(runtimeManager: runtimeManager, question: question, asker: asker, facts: facts)
                .map { Draft(text: $0, engine: "llama") }
        case nil:
            return nil
        }
    }

    /// The local model's draft: the base-model transcript prompt with answer-sized options. Static
    /// so the answer eval measures exactly what the app runs.
    static func draftLocally(
        runtimeManager: LlamaRuntimeManager, question: String, asker: String?, facts: [AnswerPromptRenderer.Fact]
    ) async throws -> String? {
        let prompt = AnswerPromptRenderer.basePrompt(question: question, asker: asker, facts: facts)
        var options = LlamaGenerationOptions(
            maxPredictionTokens: 120, temperature: 0.2, topK: 20, topP: 0.9, minP: 0.05,
            repetitionPenalty: 1.05, seed: 42
        )
        // An answer can be several sentences; autocomplete's stop at the first sentence end would
        // cut it short. It ends where the transcript's next turn would begin instead.
        options.sentenceStopMinimumTokens = .max
        options.stopSequences = AnswerPromptRenderer.stopSequences(asker: asker)
        let output = try await runtimeManager.generate(prompt: prompt, options: options)
        return AnswerPromptRenderer.cleanedAnswer(output.text, asker: asker)
    }

    private func draftWithApple(question: String, asker: String?, facts: [AnswerPromptRenderer.Fact]) async throws -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), let model = availability.systemLanguageModel {
            // A fresh session per draft: its instructions differ from autocomplete's, and a
            // transcript carried between drafts would mix one question's facts into the next.
            let session = LanguageModelSession(model: model, instructions: AnswerPromptRenderer.appleInstructions)
            let prompt = AnswerPromptRenderer.applePrompt(question: question, asker: asker, facts: facts)
            let response = try await session.respond(
                to: prompt, options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 200)
            )
            return AnswerPromptRenderer.cleanedAnswer(response.content, asker: asker, cutsAtStopSequences: false)
        }
        #endif
        return nil
    }
}
