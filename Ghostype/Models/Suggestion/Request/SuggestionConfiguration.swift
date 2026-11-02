import Foundation

/// Generation limits and user-selected behavior shared by request construction and every backend.
/// These values are immutable snapshots so asynchronous work cannot observe settings changing mid-request.

/// Closed integer range a suggestion's word count should fall within.
/// Used by both the curated `SuggestionWordCountPreset` and the user-defined custom range so the
/// prompt builder and token-budget math have a single shape to consume.
struct SuggestionWordRange: Equatable, Hashable, Sendable {
    let lowWords: Int
    let highWords: Int
    /// "Current word only": finish the word at the caret and never start the next one. The 1-word
    /// bounds keep the token budget minimal; `SuggestionLengthPolicy.currentWordOnly` does the cut.
    var isCurrentWordOnly = false

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
    var promptInstruction: String {
        isCurrentWordOnly
            ? "Return only the rest of the word being typed."
            : "Return only the next \(lowWords) to \(highWords) words."
    }
}

/// User-facing presets that bound how long one inline suggestion may be.
/// Treating this as an enum keeps the UI and prompt policy in one source of truth.
enum SuggestionWordCountPreset: String, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
    case currentWord = "word"
    case twoToFour = "2-4"
    case fourToSeven = "4-7"
    case sevenToTwelve = "7-12"
    case twelveToTwenty = "12-20"

    var id: String { rawValue }

    var displayLabel: String {
        self == .currentWord ? "Current word only" : "\(rawValue) words"
    }

    /// The shared `SuggestionWordRange` shape so the prompt builder and token-budget math can
    /// consume presets and custom ranges identically.
    var range: SuggestionWordRange {
        switch self {
        case .currentWord:
            return SuggestionWordRange(lowWords: 1, highWords: 1, isCurrentWordOnly: true)
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
    /// Optional explicit seed for deterministic llama sampling.
    /// Production leaves this nil so LlamaRuntimeCore supplies its stable default seed.
    /// Tests and microbenches can override it to compare sampler state across cache paths.
    let randomSeed: UInt32?
    var maxPrefixWords: Int
    var maxPrefixCharacters: Int
    /// When true, a prefix longer than the window is cut at a start that moves only in half-window
    /// steps (see `SuggestionRequestFactory.truncatedPromptPrefix`), so the prompt head stays the same
    /// across keystrokes and the runtime can reuse its cache. Set from the Speed pane.
    var stablePrefixWindow = false
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
    var llamaPromptTokenBudget: Int
    /// Characters of on-screen text the local prompt may carry (Speed pane "Screen text").
    var maxScreenCharacters = SpeedSettings.defaultScreenCharacters
    /// Shipped first-launch default for the user's saved profile.
    /// `SuggestionSettingsModel` persists the user's real preference; configuration only provides
    /// the app's starting value for a fresh install.
    let defaultUserName: String?
    let defaultWordCountPreset: SuggestionWordCountPreset

    let focusPollIntervalMilliseconds: Int

    /// Output reserve built into the configured llama prompt budget. It covers the default
    /// single-line request (12-20 words, 26 tokens) with room to spare; a request that asks for
    /// more has the excess taken out of its own prompt (`SuggestionRequestFactory.promptTokenBudget`).
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
        repetitionPenalty: 1.025,
        randomSeed: nil,
        // The llama prefix window is bounded by the token budget below (what the model's context
        // can hold after the preface), not by a word cap: a 150-word cap left most of a long
        // document out of the prompt, and the model's sense of the topic with it. The caps here
        // only stop pathological fields (a megabyte of log text) from being windowed each poll.
        // Latency honesty: dense and sliding-window models (Gemma, via the native `swa_full`
        // cache) prefill the window once per field, and every keystroke after that decodes only
        // the delta. Hybrid/recurrent catalog models restore from a near-caret checkpoint and
        // re-prefill when an edit lands before it, so there the wider window costs prefill only
        // in long-document sessions, which is exactly where it buys quality.
        //
        // 2026-10-09: narrowed for latency. The catalog models re-prefill the whole prefix on
        // every keystroke, so a 14k window costs ~2s per suggestion on the nano model and more
        // on larger ones. For autocomplete the current + previous paragraphs carry the signal;
        // 4k chars (≈1000 tokens) prefills ~3x faster while keeping the relevant context. The
        // personalization sections (vocabulary, history, instructions) matter more than raw
        // prefix length for "magic" completions.
        maxPrefixWords: 350,
        maxPrefixCharacters: 2000,
        // Apple's on-device model has a 4096-token shared context. Even with instructions plus
        // visual/clipboard context, there is room to send ~3x the llama window before crowding
        // the prompt, and the extra surrounding sentences materially help mid-thought completions.
        maxPrefixWordsFoundationModel: 150,
        maxPrefixCharactersFoundationModel: 2500,
        maxSuffixCharacters: 192,
        // Derived from the runtime constant so a context-window change can never silently
        // desynchronize the prompt budget from the KV capacity the model actually has.
        llamaPromptTokenBudget: SuggestionConfiguration.derivedLlamaPromptTokenBudget,
        // Seed the profile settings with lightweight defaults on first launch. No name until the
        // user sets one: the prompt signs with it after a valediction (`SignOffCue`), and the
        // endpoint backend can carry that prompt off the Mac, so a real name is an explicit opt-in
        // and a placeholder would sign every user's mail with someone else's name.
        defaultUserName: nil,
        defaultWordCountPreset: .fourToSeven,
        focusPollIntervalMilliseconds: 50
    )
}

/// The Speed pane's toggles. They are read straight from `UserDefaults` (like the coordinator's
/// speculative-prefetch switch) and folded into the request configuration per request, so a toggle
/// takes effect on the next keystroke without threading through the settings snapshot.
/// "Match Text Size" (Settings → Appearance): ghost text takes exactly the size of the text it
/// continues, ignoring the size multiplier and the smallest/largest limits. Read live by
/// `OverlayController` at present time, like the other ghost-size settings.
enum GhostTextSizeSettings {
    static let matchTextSizeKey = "ghostypeMatchTextSize"

    static func isMatchTextSizeEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: matchTextSizeKey) as? Bool ?? true
    }
}

enum SpeedSettings {
    static let stablePrefixWindowKey = "ghostypeSpeedStablePrefixWindow"
    static let shortContextKey = "ghostypeSpeedShortContext"
    static let autoTuneKey = "ghostypeSpeedAutoTune"
    /// Window used by "Shorter context": the current paragraph or two, about a third of the default.
    static let shortPrefixCharacters = 800
    static let shortPrefixWords = 150

    static func isStablePrefixWindowEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: stablePrefixWindowKey) as? Bool ?? true
    }

    static func isShortContextEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: shortContextKey) as? Bool ?? false
    }

    /// Auto-tune (default ON): Ghostype measures its own latency and switches short context
    /// on/off by itself. The manual toggle still wins when auto-tune is OFF.
    static func isAutoTuneEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: autoTuneKey) as? Bool ?? true
    }

    static let lightFocusChecksKey = "ghostypeSpeedLightFocusChecks"
    static let lightScreenReadingKey = "ghostypeSpeedLightScreenReading"

    /// Default ON: keystrokes already force a focus read, so the timer only has to catch clicks
    /// and app switches quickly while a suggestion is on screen.
    nonisolated static func isLightFocusChecksEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: lightFocusChecksKey) as? Bool ?? true
    }

    /// Default OFF: fast OCR costs some accuracy in the screen text the model reads.
    nonisolated static func isLightScreenReadingEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: lightScreenReadingKey) as? Bool ?? false
    }

    /// Speed pane caps. Screen text is in characters; the prompt cap is in tokens and can only
    /// lower the derived budget, which is already the most the model's context window holds.
    static let screenCharactersKey = "ghostypeSpeedScreenCharacters"
    static let promptTokensKey = "ghostypeSpeedPromptTokens"
    static let defaultScreenCharacters = 4000
    static let screenCharactersRange = 0...8000
    static var promptTokensRange: ClosedRange<Int> { 300...SuggestionConfiguration.derivedLlamaPromptTokenBudget }

    static func screenCharacters(_ defaults: UserDefaults) -> Int {
        let value = defaults.object(forKey: screenCharactersKey) as? Int ?? defaultScreenCharacters
        return min(max(value, screenCharactersRange.lowerBound), screenCharactersRange.upperBound)
    }

    static func promptTokens(_ defaults: UserDefaults) -> Int {
        let value = defaults.object(forKey: promptTokensKey) as? Int ?? promptTokensRange.upperBound
        return min(max(value, promptTokensRange.lowerBound), promptTokensRange.upperBound)
    }

    /// The hint shown next to each box: what the chosen number trades.
    static func screenCharactersHint(_ value: Int) -> String {
        switch value {
        case 3000...: "High: most screen detail, slowest after the screen changes"
        case 1500..<3000: "Medium: balanced"
        case 1..<1500: "Low: fastest, little screen detail"
        default: "Off: no screen text in the prompt"
        }
    }

    static func promptTokensHint(_ value: Int) -> String {
        switch value {
        case 1500...: "High: full context, slowest when the prompt is re-read"
        case 900..<1500: "Medium: balanced"
        default: "Low: fastest, least context"
        }
    }

    static func applied(
        to base: SuggestionConfiguration,
        defaults: UserDefaults,
        autoTuner: LatencyAutoTuner? = nil
    ) -> SuggestionConfiguration {
        var configuration = base
        configuration.stablePrefixWindow = isStablePrefixWindowEnabled(defaults)
        configuration.maxScreenCharacters = screenCharacters(defaults)
        configuration.llamaPromptTokenBudget = min(base.llamaPromptTokenBudget, promptTokens(defaults))
        let shortContext: Bool
        if isAutoTuneEnabled(defaults), let autoTuner {
            // Auto-tune overrides the manual toggle: the measured latency decides.
            shortContext = autoTuner.shouldUseShortContext(current: isShortContextEnabled(defaults))
        } else {
            shortContext = isShortContextEnabled(defaults)
        }
        if shortContext {
            configuration.maxPrefixCharacters = min(base.maxPrefixCharacters, shortPrefixCharacters)
            configuration.maxPrefixWords = min(base.maxPrefixWords, shortPrefixWords)
        }
        return configuration
    }
}

/// Tracks recent request latencies and decides whether short context should be on.
///
/// Why auto-tune: the Speed pane's short-context toggle is a manual guess — the user has to
/// know their machine is slow and remember to flip it. Ghostype already measures every
/// request's latency, so it can adapt on its own: slow machine → shorter context (faster);
/// fast machine → full context (better quality).
///
/// Hysteresis: the thresholds are far apart (300ms / 800ms) and the decision sticks until
/// the median crosses the opposite threshold, so the setting never flip-flops when latency
/// hovers near a boundary.
struct LatencyAutoTuner {
    /// Enable short context when the median latency exceeds this (too slow to feel instant).
    static let enableThresholdMs = 800
    /// Disable short context when the median latency drops below this (fast enough for full context).
    static let disableThresholdMs = 300
    /// Samples kept: enough to smooth out one slow outlier, few enough to react within seconds.
    static let maxSamples = 20

    private var samples: [Int] = []

    /// Records a completed request's latency in milliseconds.
    mutating func record(latencyMs: Int) {
        samples.append(latencyMs)
        if samples.count > Self.maxSamples { samples.removeFirst(samples.count - Self.maxSamples) }
    }

    /// Median latency of recent requests, nil when no samples yet.
    var medianLatencyMs: Int? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    /// Whether short context should be on, given its current state. With too few samples
    /// (< 3) the current state is kept — don't react to one cold-start outlier.
    func shouldUseShortContext(current: Bool) -> Bool {
        guard samples.count >= 3, let median = medianLatencyMs else { return current }
        if median > Self.enableThresholdMs { return true }
        if median < Self.disableThresholdMs { return false }
        return current
    }
}
