import Foundation

/// File overview:
/// Declarative first-token deny lists for suppressing chat residue from instruction-tuned models.
///
/// When instruction-tuned models (Gemma-instruct, Qwen3, etc.) are used for inline autocomplete,
/// they sometimes begin their response with conversational tokens that belong to a "helpful
/// assistant" reply rather than the user's text continuation — phrases like "Sure,", "Here's",
/// "I ", or leading newlines.
///
/// This file defines the human-readable deny strings per model. The strings are resolved to
/// concrete token IDs at model-load time inside `LlamaRuntimeCore`, since tokenization depends
/// on the loaded model's vocabulary.
///
/// Architectural placement: `Support/` because this is pure, deterministic data with no side
/// effects, runtime dependencies, or OS interactions. It changes at a different rate than
/// the runtime code that consumes it.

/// Provides per-model deny lists of strings that should never appear as the first generated token
/// during inline autocomplete. Each string represents a common chat-residue opener that
/// instruction-tuned models tend to emit.
///
/// The deny list is intentionally small and conservative. False positives (blocking a legitimate
/// continuation) are possible but unlikely in inline autocomplete contexts, where starting a
/// suggestion with "Sure" or "Here's" is almost never the right continuation of typed text.
enum FirstTokenDenyList {

    /// Returns the deny strings for the given model filename.
    ///
    /// Known built-in models get curated lists based on observed chat-residue patterns.
    /// Unknown models (user-provided custom GGUFs) get a conservative default list that
    /// covers the most common English-language chat openers without being overly aggressive.
    ///
    /// - Parameter modelFilename: The basename of the loaded GGUF file (e.g. "gemma-3-1b-it-Q4_K_M.gguf").
    /// - Returns: An array of strings whose leading token(s) should be denied at generation position 0.
    static func denyStrings(for modelFilename: String) -> [String] {
        switch modelFilename {

        // Gemma instruct models are instruction-tuned on conversational data and frequently
        // emit politeness openers and first-person narration before the actual continuation.
        case "gemma-3-1b-it-Q4_K_M.gguf",
             "gemma-3n-E4B-it-Q4_K_M.gguf":
            return Self.gemmaInstructDenyStrings

        // Qwen3 is multilingual and sometimes emits Chinese-language chat openers
        // in addition to the standard English ones.
        case "Qwen3-0.6B-Q4_K_M.gguf":
            return Self.qwen3DenyStrings

        // Conservative fallback for user-provided custom models.
        // Only blocks the most universally problematic chat-residue tokens.
        default:
            return Self.defaultDenyStrings
        }
    }

    // MARK: - Per-Model Deny String Lists

    /// Gemma-instruct models: broad English chat-residue coverage.
    private static let gemmaInstructDenyStrings: [String] = [
        "Sure",
        "Here",
        "I ",
        "Let me",
        "Of course",
        "Certainly",
    ]

    /// Qwen3 models: English chat residue plus common Chinese-language openers.
    /// "好的" (hǎo de, "okay") and "当然" (dāng rán, "of course") are frequent Qwen chat starters.
    private static let qwen3DenyStrings: [String] = [
        "Sure",
        "Here",
        "I ",
        "Let",
        "好的",
        "当然",
    ]

    /// Conservative default for unknown/custom models.
    /// Keeps the list minimal to avoid false positives on models we haven't profiled.
    private static let defaultDenyStrings: [String] = [
        "Sure",
        "Here",
        "I ",
    ]
}
