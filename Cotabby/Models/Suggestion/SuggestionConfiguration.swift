import Foundation

/// Generation limits and user-selected behavior shared by request construction and every backend.
/// These values are immutable snapshots so asynchronous work cannot observe settings changing mid-request.

/// Closed integer range a suggestion's word count should fall within.
/// Used by both the curated `SuggestionWordCountPreset` and the user-defined custom range so the
/// prompt builder and token-budget math have a single shape to consume.
struct SuggestionWordRange: Equatable, Hashable, Sendable {
    let lowWords: Int
    let highWords: Int

    /// Hard bounds for any range that ends up driving generation. The floor of 1 keeps the model
    /// from being asked for zero words; the ceiling caps how much we'll plan for so a typo'd "9999"
    /// can't blow out the token budget.
    static let minimumWord: Int = 1
    static let maximumWord: Int = 50

    /// Clamps both ends to `[minimumWord, maximumWord]` and ensures low <= high (snapping high up to
    /// low when the user temporarily inverts them via two separate steppers).
    static func clamped(low: Int, high: Int) -> SuggestionWordRange {
        let clampedLow = min(max(low, minimumWord), maximumWord)
        let clampedHigh = min(max(high, clampedLow), maximumWord)
        return SuggestionWordRange(lowWords: clampedLow, highWords: clampedHigh)
    }

    var compactLabel: String { "\(lowWords)-\(highWords) w" }
    var promptInstruction: String { "Return only the next \(lowWords) to \(highWords) words." }
}

/// User-facing presets that bound how long one inline suggestion may be.
/// Treating this as an enum keeps the UI and prompt policy in one source of truth.
enum SuggestionWordCountPreset: String, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
    case twoToFour = "2-4"
    case fourToSeven = "4-7"
    case sevenToTwelve = "7-12"
    case twelveToTwenty = "12-20"

    var id: String { rawValue }

    var displayLabel: String {
        "\(rawValue) words"
    }

    /// The shared `SuggestionWordRange` shape so the prompt builder and token-budget math can
    /// consume presets and custom ranges identically.
    var range: SuggestionWordRange {
        switch self {
        case .twoToFour:
            return SuggestionWordRange(lowWords: 2, highWords: 4)
        case .fourToSeven:
            return SuggestionWordRange(lowWords: 4, highWords: 7)
        case .sevenToTwelve:
            return SuggestionWordRange(lowWords: 7, highWords: 12)
        case .twelveToTwenty:
            return SuggestionWordRange(lowWords: 12, highWords: 20)
        }
    }

}

extension SuggestionWordRange {
    /// Maps a word range upper bound and a per-word factor onto a token budget, rounded up so the
    /// cap lands at or just past the upper word bound rather than systematically under it.
    static func predictionTokenBudget(highWords: Int, tokensPerWord: Double) -> Int {
        Int(ceil(Double(highWords) * tokensPerWord))
    }
}

/// Persisted indicator mode values. Only `hidden` and `fieldEdgeIcon` are active;
/// the enum exists so UserDefaults round-trips through a stable raw value.
enum ActivationIndicatorMode: String, Equatable, Hashable, Sendable {
    case hidden
    case fieldEdgeIcon
}

/// Runtime knobs for the inline-completion pipeline.
/// Keeping these in one struct makes it easier to reason about product defaults versus
/// experimental tuning without scattering magic numbers through the coordinator.
struct SuggestionConfiguration: Equatable, Sendable {
    let maxPredictionTokens: Int
    let debounceMilliseconds: Int
    let temperature: Double
    let topK: Int
    let topP: Double
    let minP: Double
    let repetitionPenalty: Double
    /// Optional fixed seed for deterministic llama sampling.
    /// Production keeps this nil so suggestions can vary naturally; tests and microbenches can set
    /// it to prove cached and uncached decoding produce the same output for the same sampler state.
    let randomSeed: UInt32?
    let maxPrefixWords: Int
    let maxPrefixCharacters: Int
    /// Foundation Models has a noticeably larger shared context than the local llama path, so the
    /// FM-selected request gets a separate (larger) prefix budget. Setting this above the llama
    /// caps avoids crowding instructions while keeping the local-continuation focus.
    let maxPrefixWordsFoundationModel: Int
    let maxPrefixCharactersFoundationModel: Int
    let maxSuffixCharacters: Int
    /// Estimated-token ceiling for the llama prompt (preface + prefix). Derived from the runtime's
    /// per-sequence context window minus the output budget and a safety margin, so the renderer
    /// truncates against what the model can actually hold instead of a flat character guess that
    /// misjudges code, CJK, and punctuation-heavy text.
    let llamaPromptTokenBudget: Int
    /// Shipped first-launch default for the user's saved profile.
    /// `SuggestionSettingsModel` persists the user's real preference; configuration only provides
    /// the app's starting value for a fresh install.
    let defaultUserName: String?
    let defaultWordCountPreset: SuggestionWordCountPreset
    let focusPollIntervalMilliseconds: Int

    /// Output ceiling reserved out of the llama context window when sizing the prompt budget:
    /// the largest realistic per-request token budget (multi-line doubles the 26-token default).
    static let llamaPromptOutputCeilingTokens = 50
    /// Margin for BOS plus token-estimator error; the estimator skews conservative, so real
    /// prompts land under the derived budget.
    static let llamaPromptSafetyMarginTokens = 64
    /// The per-sequence KV capacity minus the output ceiling and safety margin. Computed from
    /// `LlamaRuntimeConfiguration.default` so the two constants cannot drift apart silently.
    static var derivedLlamaPromptTokenBudget: Int {
        Int(LlamaRuntimeConfiguration.default.contextWindowTokens)
            - llamaPromptOutputCeilingTokens
            - llamaPromptSafetyMarginTokens
    }

    /// The configuration shipped by the app today.
    /// These are product defaults, not temporary debug overrides.
    static let standard = SuggestionConfiguration(
        // Floor for the per-request token budget (see SuggestionRequestFactory.activeMaxPredictionTokens).
        // Held at the smallest word-count preset (2-4 words) so that preset's budget governs instead
        // of being silently raised; keeps ghost text short, fast, and easy to accept.
        maxPredictionTokens: 5,
        // Aggressive debounce: 20ms keeps time-to-first-suggestion low while still collapsing
        // bursts (superseded generations are cancelled; the host-publish poll absorbs AX lag).
        debounceMilliseconds: 20,
        // Low temperature keeps inline completions stable and less likely to drift.
        temperature: 0.1,
        topK: 20,
        topP: 0.7,
        minP: 0.08,
        repetitionPenalty: 1.05,
        randomSeed: nil,
        maxPrefixWords: 150,
        // The llama prefix window matches the Foundation Models one: the extra preceding sentences
        // carry the topic and voice that multi-paragraph email/docs continuations need, and the
        // token budget below keeps the total prompt bounded by what the model can hold. Latency
        // honesty: where KV prefix reuse works (dense models), the larger window is prefilled once
        // per field; the hybrid/SWA catalog models reject partial trims and re-prefill per request,
        // so there the wider window costs prefill only when the field actually holds more than the
        // old 1000-char cap, i.e. long-document sessions, which is exactly where it buys quality.
        maxPrefixCharacters: 2500,
        // Apple's on-device model has a 4096-token shared context. Even with instructions plus
        // visual/clipboard context, there is room to send ~3x the llama window before crowding
        // the prompt, and the extra surrounding sentences materially help mid-thought completions.
        maxPrefixWordsFoundationModel: 150,
        maxPrefixCharactersFoundationModel: 2500,
        maxSuffixCharacters: 192,
        // Derived from the runtime constant so a context-window change can never silently
        // desynchronize the prompt budget from the KV capacity the model actually has.
        llamaPromptTokenBudget: SuggestionConfiguration.derivedLlamaPromptTokenBudget,
        // Seed the profile settings with lightweight defaults on first launch.
        defaultUserName: "Jacob",
        defaultWordCountPreset: .twelveToTwenty,
        focusPollIntervalMilliseconds: 50
    )
}
