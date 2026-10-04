import Foundation
import Logging
import Translation

/// One way to translate text on this Mac.
@MainActor
protocol TranslationEngine: AnyObject {
    func availability(from source: String, to target: String) async -> TranslationPairAvailability
    func translate(_ text: String, from source: String, to target: String) async throws -> String
}

/// Apple's on-device Translation framework: fast (tens of milliseconds once warm), offline, and the
/// best quality for the ~20 languages it covers. Sessions are created per language pair from the
/// installed language files (`init(installedSource:target:)`, macOS 26) and reused, because the first
/// translation on a session loads its model.
@MainActor
final class AppleTranslationEngine: TranslationEngine {
    private var sessions: [String: AnyObject] = [:]

    func availability(from source: String, to target: String) async -> TranslationPairAvailability {
        guard #available(macOS 26.0, *) else { return .unavailable }
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: source),
            to: Locale.Language(identifier: target)
        )
        switch status {
        case .installed: return .ready
        case .supported: return .needsDownload
        case .unsupported: return .unavailable
        @unknown default: return .unavailable
        }
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        guard #available(macOS 26.0, *) else { throw TranslationError.unsupportedPair(source: source, target: target) }
        switch await availability(from: source, to: target) {
        case .ready: break
        case .needsDownload: throw TranslationError.needsDownload(source: source, target: target)
        case .localModel, .unavailable: throw TranslationError.unsupportedPair(source: source, target: target)
        }
        let key = "\(source)>\(target)"
        let session: TranslationSession
        if let existing = sessions[key] as? TranslationSession {
            session = existing
        } else {
            session = TranslationSession(
                installedSource: Locale.Language(identifier: source),
                target: Locale.Language(identifier: target)
            )
            sessions[key] = session
        }
        let response = try await session.translate(text)
        return response.targetText
    }
}

/// Translates with the selected Open Source model for pairs Apple Translation does not cover
/// (Macedonian). The bundled models are base models, so this uses a few-shot prompt
/// (`FewShotTranslationPrompt`) rather than an instruction. It shares the local runtime, and its
/// lock, with autocomplete; a translation waits for an in-flight suggestion and vice versa.
@MainActor
final class LocalModelTranslationEngine: TranslationEngine {
    private let runtimeManager: LlamaRuntimeManager
    private let hasModel: @MainActor () -> Bool

    init(runtimeManager: LlamaRuntimeManager, hasModel: @escaping @MainActor () -> Bool) {
        self.runtimeManager = runtimeManager
        self.hasModel = hasModel
    }

    func availability(from source: String, to target: String) async -> TranslationPairAvailability {
        guard FewShotTranslationPrompt.supports(source: source, target: target) else { return .unavailable }
        return hasModel() ? .localModel : .unavailable
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        guard hasModel() else { throw TranslationError.noLocalModel }
        guard let prompt = FewShotTranslationPrompt.prompt(for: text, source: source, target: target) else {
            throw TranslationError.unsupportedPair(source: source, target: target)
        }
        let wordCount = text.split(whereSeparator: \.isWhitespace).count
        var options = LlamaGenerationOptions(
            // Translations run a little longer than their source in tokens; cap runaway output.
            maxPredictionTokens: min(256, wordCount * 4 + 16),
            temperature: 0.2,
            topK: 20,
            topP: 0.9,
            minP: 0.05,
            repetitionPenalty: 1.05,
            seed: nil
        )
        // One line per translation: decoding stops at the line break the examples end with.
        options.singleLine = true
        // The autocomplete stop at the first sentence end would cut a two-sentence message in half.
        options.sentenceStopMinimumTokens = .max
        let output = try await runtimeManager.generate(prompt: prompt, options: options)
        let cleaned = FewShotTranslationPrompt.cleanedOutput(output.text)
        guard !cleaned.isEmpty else { throw TranslationError.emptyResult }
        return cleaned
    }
}

/// The app's single translation entry point: detects nothing itself, picks the engine for a pair
/// (Apple first, the local model only where Apple cannot), and caches every result in memory.
///
/// Owned by `CotabbyAppEnvironment`; the incoming-message coordinator and the reply controller use
/// it, and the Translation settings pane reads `availability` for its per-language status.
@MainActor
final class TranslationService {
    private let apple: any TranslationEngine
    private let local: any TranslationEngine
    private var cache = TranslationCache()

    init(apple: any TranslationEngine, local: any TranslationEngine) {
        self.apple = apple
        self.local = local
    }

    func availability(from source: String, to target: String) async -> TranslationPairAvailability {
        let appleStatus = await apple.availability(from: source, to: target)
        if appleStatus == .ready || appleStatus == .needsDownload { return appleStatus }
        return await local.availability(from: source, to: target)
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> TranslationResult {
        if let cached = cache.value(for: text, target: target) { return cached }
        let engine: any TranslationEngine
        switch await apple.availability(from: source, to: target) {
        case .ready:
            engine = apple
        case .needsDownload:
            // The local model is a weaker stand-in; prefer it only when it can actually run.
            engine = await local.availability(from: source, to: target) == .localModel ? local : apple
        case .localModel, .unavailable:
            engine = local
        }
        let translated = try await engine.translate(text, from: source, to: target)
        let result = TranslationResult(
            sourceText: text, sourceLanguage: source, targetLanguage: target, translatedText: translated
        )
        cache.store(result)
        return result
    }

    /// Drops every cached translation, e.g. when translation is turned off.
    func clearCache() {
        cache.removeAll()
    }
}
