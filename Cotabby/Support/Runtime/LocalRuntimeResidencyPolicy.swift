import Foundation

/// Decides whether the in-process llama runtime should keep its model loaded in memory for a given
/// engine configuration.
///
/// Why this exists as its own type: the answer depends on three settings (the engine plus the two
/// Apple Intelligence fallback switches), and two different places act on it. `AppDelegate` starts
/// or stops the runtime when any of them changes, and the fallback model picker in Settings decides
/// whether choosing a model should load it now or only record it. One pure rule keeps those callers
/// from drifting apart and lets tests pin the table without AppKit or a real model.
///
/// "Not resident" does not forbid loading. Under Apple Intelligence the language fallback still
/// loads the selected model on demand (`LlamaRuntimeManager.preparedRuntime()`); this policy only
/// answers whether Cotabby should load it ahead of time and keep it there.
enum LocalRuntimeResidencyPolicy {
    static func keepsModelLoaded(
        engine: SuggestionEngineKind,
        isAppleLanguageFallbackEnabled: Bool,
        keepsFallbackModelLoaded: Bool
    ) -> Bool {
        switch engine {
        case .llamaOpenSource:
            return true
        case .appleIntelligence:
            // Both switches must be on: a kept-loaded model is useless when the fallback that
            // would use it is turned off.
            return isAppleLanguageFallbackEnabled && keepsFallbackModelLoaded
        case .openAICompatible:
            // The endpoint runs its own model, so a resident GGUF would only double memory use.
            return false
        }
    }
}
