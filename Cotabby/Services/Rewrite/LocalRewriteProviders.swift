import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// File overview:
/// The two rewrite providers that run Cotabby's in-process models, one per autocomplete engine:
/// `AppleIntelligenceRewriteProvider` (the Foundation Models path, which follows instructions) and
/// `OpenSourceRewriteProvider` (the selected llama model with the base-model example prompt: weaker,
/// which the Settings pane calls "basic quality"). Neither has a rewrite-only model; both use what
/// autocomplete uses. The llama provider shares the runtime with autocomplete: `LlamaRuntimeCore`
/// serializes generations, so a rewrite waits for an in-flight suggestion, and the next suggestion
/// re-decodes its own prompt because the core reuses a cached prefix only when its tokens still
/// match. Owned by `RewriteEngine`. `PartialRelay`, which the llama path needs, lives here too.

/// Rewrites with Apple Intelligence: the instruct prompt, a fresh session per rewrite.
@MainActor
final class AppleIntelligenceRewriteProvider: RewriteProviding {
    private let availability: FoundationModelAvailabilityService

    init(availability: FoundationModelAvailabilityService) {
        self.availability = availability
    }

    nonisolated deinit {}

    var isAvailable: Bool {
        if #available(macOS 26.0, *) {
            #if canImport(FoundationModels)
            return availability.isAvailable && availability.systemLanguageModel != nil
            #endif
        }
        return false
    }

    var sendsOffDevice: Bool { false }

    var unavailableReason: String? {
        isAvailable ? nil : availability.userVisibleMessage
    }

    func rewrite(_ request: RewriteRequest, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), isAvailable, let model = availability.systemLanguageModel {
            let prompt = RewritePromptBuilder.instructPrompt(request)
            // A fresh session per rewrite: a transcript carried between rewrites would mix one
            // draft's facts into the next.
            let session = LanguageModelSession(model: model, instructions: prompt.system)
            let response = try await session.respond(
                to: prompt.user,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: RewritePromptBuilder.tokenBudget(request))
            )
            onPartial(response.content)
            return response.content
        }
        #endif
        throw RewriteError.noProvider
    }
}

/// Rewrites with the llama model autocomplete has selected (the base prompt with an example).
@MainActor
final class OpenSourceRewriteProvider: RewriteProviding {
    private let runtimeManager: LlamaRuntimeManager
    private let hasLocalModel: @MainActor () -> Bool

    init(runtimeManager: LlamaRuntimeManager, hasLocalModel: @escaping @MainActor () -> Bool) {
        self.runtimeManager = runtimeManager
        self.hasLocalModel = hasLocalModel
    }

    nonisolated deinit {}

    var isAvailable: Bool { hasLocalModel() }
    var sendsOffDevice: Bool { false }
    var unavailableReason: String? {
        hasLocalModel() ? nil : "No Open Source model is installed. Add one in Settings → Engine & Model."
    }

    func rewrite(_ request: RewriteRequest, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        guard hasLocalModel() else { throw RewriteError.noProvider }
        var options = LlamaGenerationOptions(
            maxPredictionTokens: RewritePromptBuilder.tokenBudget(request), temperature: 0.3, topK: 40, topP: 0.9, minP: 0.05,
            repetitionPenalty: 1.05, seed: 42
        )
        // A rewrite can be several sentences; autocomplete's stop at the first sentence end would cut it.
        options.sentenceStopMinimumTokens = .max
        options.stopSequences = RewritePromptBuilder.baseStopSequences
        let relay = PartialRelay(deliver: onPartial)
        // Stop delivery on every exit, including a thrown error, so no partial can arrive after
        // this function has returned.
        defer { relay.finish() }
        let output = try await runtimeManager.generate(
            prompt: RewritePromptBuilder.basePrompt(request), options: options,
            onPartialRawText: { text in relay.send(RewritePromptBuilder.cutAtBaseStop(text)) }
        )
        return RewritePromptBuilder.cutAtBaseStop(output.text)
    }
}

/// Delivers streamed partials to the main actor in order and never after the rewrite has
/// returned. The runtime calls back off the main actor; each partial carries a sequence number,
/// and the main-actor side drops any partial older than the newest delivered, and all partials
/// once `finish()` ran.
final class PartialRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var nextSequence = 0
    private var deliveredSequence = -1
    private var finished = false
    private let deliver: @MainActor (String) -> Void

    init(deliver: @escaping @MainActor (String) -> Void) { self.deliver = deliver }

    /// Called from the runtime's callback thread.
    func send(_ text: String) {
        lock.lock()
        let sequence = nextSequence
        nextSequence += 1
        lock.unlock()
        Task { @MainActor in self.receive(text, sequence: sequence) }
    }

    @MainActor private func receive(_ text: String, sequence: Int) {
        lock.lock()
        let stale = finished || sequence <= deliveredSequence
        if !stale { deliveredSequence = sequence }
        lock.unlock()
        if !stale { deliver(text) }
    }

    /// Stops delivery; called before the rewrite returns its final text.
    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }
}
