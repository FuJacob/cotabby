import CoreGraphics
import Foundation

/// File overview:
/// Defines the pure value types that describe Cotabby's autocomplete domain:
/// configuration, generation requests, normalized model output, active suggestion sessions,
/// and overlay visibility.
///
/// This file is intentionally free of AppKit, AX, and runtime side effects so maintainers can
/// understand the core state machine without reading OS integration code first.

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

    var displayLabel: String { "\(lowWords)-\(highWords) words" }
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

    /// Compact labels are useful in tight menu-bar controls where the full descriptive copy
    /// would dominate the layout.
    var compactLabel: String {
        "\(rawValue) w"
    }

    var promptInstruction: String {
        switch self {
        case .twoToFour:
            return "Return only the next 2 to 4 words."
        case .fourToSeven:
            return "Return only the next 4 to 7 words."
        case .sevenToTwelve:
            return "Return only the next 7 to 12 words."
        case .twelveToTwenty:
            return "Return only the next 12 to 20 words."
        }
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

    /// Token budget is the sole governor of completion length on the local model (the in-prompt
    /// word-range cue was removed), so it must track the upper word bound closely. Now derived from
    /// the language-aware factor in `LanguageCatalog`; this convenience returns the English-default
    /// number for callers/tests that don't have a language context handy. History: a ~1.5x sizing
    /// (6/11/18/30) still overran because real prose uses fewer tokens per word than that assumed,
    /// and an earlier 50% bump overran further, e.g. ~12 words on the shortest preset (#271). When
    /// unsure, bias shorter; a clipped suggestion is cheaper than one that blows past the setting.
    var suggestedPredictionTokenBudget: Int {
        SuggestionWordRange.predictionTokenBudget(
            highWords: range.highWords,
            tokensPerWord: LanguageCatalog.fallbackTokensPerWord
        )
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
    /// Shipped first-launch default for the user's saved profile.
    /// `SuggestionSettingsModel` persists the user's real preference; configuration only provides
    /// the app's starting value for a fresh install.
    let defaultUserName: String?
    let defaultWordCountPreset: SuggestionWordCountPreset
    let focusPollIntervalMilliseconds: Int

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
        maxPrefixWords: 50,
        // Prompt windows should stay small for the local llama path. Sending an entire editor
        // buffer hurts latency with little quality gain because Cotabby is only completing the
        // immediate local continuation.
        maxPrefixCharacters: 1000,
        // Apple's on-device model has a 4096-token shared context. Even with instructions plus
        // visual/clipboard context, there is room to send ~3x the llama window before crowding
        // the prompt, and the extra surrounding sentences materially help mid-thought completions.
        maxPrefixWordsFoundationModel: 150,
        maxPrefixCharactersFoundationModel: 2500,
        maxSuffixCharacters: 192,
        // Seed the profile settings with lightweight defaults on first launch.
        defaultUserName: "Jacob",
        defaultWordCountPreset: .twelveToTwenty,
        focusPollIntervalMilliseconds: 50
    )
}

/// This is the stable context used across debounce and generation boundaries.
/// It extends the AX snapshot with a monotonically increasing generation number.
struct FocusedInputContext: Equatable, Sendable {
    let applicationName: String
    let bundleIdentifier: String
    let processIdentifier: Int32
    let elementIdentifier: String
    let role: String
    let subrole: String?
    let caretRect: CGRect
    let inputFrameRect: CGRect?
    let caretQuality: CaretGeometryQuality
    /// Average character width in points observed from AX child frame measurements.
    /// Used by caret prediction after tab insertion to match the target app's actual font.
    let observedCharWidth: CGFloat?
    let precedingText: String
    let trailingText: String
    let selection: NSRange
    let isSecure: Bool
    /// The host field's own text font/color, carried through so the overlay can match it.
    let resolvedFieldStyle: ResolvedFieldStyle?
    /// Carries the immutable focus-observation identity across debounce/generation boundaries.
    /// Without this, later visual-context lookups could fall back to `elementIdentifier` alone and
    /// reintroduce the CFHash collision class this sequence is meant to avoid.
    let focusChangeSequence: UInt64
    let generation: UInt64

    init(snapshot: FocusedInputSnapshot, generation: UInt64) {
        applicationName = snapshot.applicationName
        bundleIdentifier = snapshot.bundleIdentifier
        processIdentifier = snapshot.processIdentifier
        elementIdentifier = snapshot.elementIdentifier
        role = snapshot.role
        subrole = snapshot.subrole
        caretRect = snapshot.caretRect
        inputFrameRect = snapshot.inputFrameRect
        caretQuality = snapshot.caretQuality
        observedCharWidth = snapshot.observedCharWidth
        precedingText = snapshot.precedingText
        trailingText = snapshot.trailingText
        selection = snapshot.selection
        isSecure = snapshot.isSecure
        resolvedFieldStyle = snapshot.resolvedFieldStyle
        focusChangeSequence = snapshot.focusChangeSequence
        self.generation = generation
    }

    var identity: FocusedInputIdentity {
        FocusedInputIdentity(
            elementIdentifier: elementIdentifier,
            focusChangeSequence: focusChangeSequence
        )
    }

    /// True when the caret is at the end of its line (only whitespace, if anything, before the next
    /// line break). Derived from `trailingText` via `CaretLinePosition`; used to decide when a
    /// mid-line completion strategy like fill-in-middle applies versus a plain forward continuation.
    var isCaretAtEndOfLine: Bool {
        CaretLinePosition.isAtEndOfLine(trailingText: trailingText)
    }

    /// Stable per-process key for the focused field, intentionally NOT including the input frame
    /// rect. The polling signature in `FocusTracker` bumps `focusChangeSequence` whenever the
    /// field's frame changes (e.g., a chat composer growing taller as the user types wraps onto a
    /// second line). For consumers that should treat self-resizing as "same field" — chief among
    /// them ghost-font stabilization — this key gives them a session identity that survives field
    /// growth. `hashValue` is randomized per process, which is fine: the key is only ever compared
    /// within one process's lifetime.
    var focusedInputIdentityKey: UInt64 {
        var hasher = Hasher()
        hasher.combine(bundleIdentifier)
        hasher.combine(processIdentifier)
        hasher.combine(elementIdentifier)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    /// Content-only fingerprint — mirrors `FocusedInputSnapshot.contentSignature`.
    /// See that type's doc comment for why `elementIdentifier` is excluded.
    var contentSignature: String {
        [
            String(selection.location),
            String(selection.length),
            precedingText,
            trailingText,
            isSecure ? "secure" : "plain"
        ].joined(separator: "::")
    }
}

/// Distinguishes a normal forward continuation from a typo-correction reply.
///
/// `.correction(typoWord:)` carries the exact word the correction was offered for, so the acceptance
/// path can confirm the live field still ends with that word before deleting it (guarding against a
/// keystroke that slipped in between), then replace it with the corrected word. This lets a
/// correction reuse the same session/overlay machinery as a plain continuation while committing as a
/// whole-word replacement.
enum SuggestionKind: Equatable, Sendable {
    case continuation
    case correction(typoWord: String)

    var isCorrection: Bool {
        if case .correction = self {
            return true
        }
        return false
    }
}

/// One generation request sent from the coordinator into the suggestion engine.
struct SuggestionRequest: Equatable, Sendable {
    let context: FocusedInputContext
    /// The truncated text immediately before the caret.
    /// This stays backend-agnostic and gives every engine access to the same local writing context
    /// even if they render prompts differently.
    let prefixText: String
    /// The canonical prompt payload for prompt-oriented backends such as the local llama runtime.
    /// Engines that prefer a separate instructions channel can derive their own request text from
    /// `prefixText` and the other shared fields instead of consuming this string directly.
    let prompt: String
    let generation: UInt64
    let maxPredictionTokens: Int
    let temperature: Double
    let topK: Int
    let topP: Double
    let minP: Double
    let repetitionPenalty: Double
    /// Optional deterministic sampler seed. `nil` preserves production randomness; tests and
    /// microbenches can set this so cached and uncached runtime paths are directly comparable.
    let randomSeed: UInt32?
    let maxSuffixCharacters: Int
    /// Explicit length guidance stays separate from user style preferences so prompt builders can
    /// order and phrase them differently per backend.
    let completionLengthInstruction: String
    /// Optional user-provided profile context. We keep this separate from base product behavior so
    /// future settings/personalization work can evolve independently from prompt safety rules.
    let userName: String?
    /// User-authored style rules rendered as additional prompt directives, subordinate to the base
    /// autocomplete/safety rules. Empty when the user has none.
    let customRules: [String]
    /// User-authored free-form context (glossary, jargon, style notes) injected verbatim into the
    /// prompt. Already trimmed and length-capped upstream so renderers can treat it as a ready-to-use
    /// string. `nil` when the user has not set it, distinguishing it from an empty-but-set value so
    /// renderers can skip the heading entirely.
    let extendedContext: String?
    /// Pre-rendered language hint built from the user's declared languages (e.g. "The user usually
    /// writes in German and English…"). `nil` when none are declared. Deliberately a hint, not an
    /// override: it tells the model to match the surrounding text and only fall back to the declared
    /// languages when that text is ambiguous, which protects code-switching.
    let languageInstruction: String?
    /// Ephemeral clipboard context captured only when the user has enabled clipboard prompting.
    let clipboardContext: String?
    /// Ephemeral screen context summary injected only when available for the active text field.
    let visualContextSummary: String?
    /// When enabled, the normalizer keeps multiple lines instead of truncating to the first line.
    let isMultiLineEnabled: Bool
    /// Correlation ID stamped onto every log line touching this request — coordinator state
    /// transitions, router selection, engine generation, LLM I/O capture, insertion. Generated by
    /// `RequestID.generate()` in `SuggestionRequestFactory`. Defaulted in the init so test fixtures
    /// that build requests directly do not need to change.
    let requestID: String

    init(
        context: FocusedInputContext,
        prefixText: String,
        prompt: String,
        generation: UInt64,
        maxPredictionTokens: Int,
        temperature: Double,
        topK: Int,
        topP: Double,
        minP: Double,
        repetitionPenalty: Double,
        randomSeed: UInt32?,
        maxSuffixCharacters: Int,
        completionLengthInstruction: String,
        userName: String?,
        customRules: [String],
        extendedContext: String? = nil,
        languageInstruction: String?,
        clipboardContext: String?,
        visualContextSummary: String?,
        isMultiLineEnabled: Bool,
        requestID: String = "req_unknown"
    ) {
        self.context = context
        self.prefixText = prefixText
        self.prompt = prompt
        self.generation = generation
        self.maxPredictionTokens = maxPredictionTokens
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.minP = minP
        self.repetitionPenalty = repetitionPenalty
        self.randomSeed = randomSeed
        self.maxSuffixCharacters = maxSuffixCharacters
        self.completionLengthInstruction = completionLengthInstruction
        self.userName = userName
        self.customRules = customRules
        self.extendedContext = extendedContext
        self.languageInstruction = languageInstruction
        self.clipboardContext = clipboardContext
        self.visualContextSummary = visualContextSummary
        self.isMultiLineEnabled = isMultiLineEnabled
        self.requestID = requestID
    }
}

/// The engine's normalized response, including raw model text for debugging.
struct SuggestionResult: Equatable, Sendable {
    let generation: UInt64
    let rawText: String
    let text: String
    let latency: TimeInterval
}

/// Represents one active inline-completion session after the model has produced a suggestion.
/// The key architectural shift is that a suggestion is no longer "fire once and forget."
/// Instead, it becomes durable interaction state that can be partially consumed over time.
struct ActiveSuggestionSession: Equatable, Sendable {
    /// The focused field state that produced the original suggestion.
    /// We keep this as the anchor so later text changes can be interpreted as:
    /// "user consumed part of the suggestion" vs "user diverged from it."
    let baseContext: FocusedInputContext
    let fullText: String
    let consumedCharacterCount: Int
    let latency: TimeInterval
    /// `.continuation` for normal forward suggestions; `.correction(typoWord:)` when the session
    /// represents a typo fix. The acceptance path branches on this so corrections always commit the
    /// whole word and replace the typo rather than appending forward text.
    let kind: SuggestionKind

    init(
        baseContext: FocusedInputContext,
        fullText: String,
        consumedCharacterCount: Int = 0,
        latency: TimeInterval,
        kind: SuggestionKind = .continuation
    ) {
        self.baseContext = baseContext
        self.fullText = fullText
        self.consumedCharacterCount = min(max(consumedCharacterCount, 0), fullText.count)
        self.latency = latency
        self.kind = kind
    }

    var acceptedText: String {
        fullText.leadingCharacters(consumedCharacterCount)
    }

    var remainingText: String {
        fullText.droppingLeadingCharacters(consumedCharacterCount)
    }

    var acceptedCount: Int {
        consumedCharacterCount
    }

    var remainingCount: Int {
        remainingText.count
    }

    /// A whitespace-only tail is effectively exhausted for inline UX.
    /// Showing "ghost spaces" is visually confusing and not worth preserving.
    var isExhausted: Bool {
        remainingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Returns a new session advanced by the accepted or typed character count.
    /// The original value stays unchanged because this type models immutable interaction state.
    func advancing(by consumedCharacters: Int) -> ActiveSuggestionSession {
        ActiveSuggestionSession(
            baseContext: baseContext,
            fullText: fullText,
            consumedCharacterCount: self.consumedCharacterCount + max(consumedCharacters, 0),
            latency: latency,
            kind: kind
        )
    }

    /// Rebuilds the session from a fully observed live editor state during reconciliation.
    /// This is useful when AX catches up after optimistic UI updates such as partial Tab accepts.
    func withConsumedCharacters(_ consumedCharacters: Int) -> ActiveSuggestionSession {
        ActiveSuggestionSession(
            baseContext: baseContext,
            fullText: fullText,
            consumedCharacterCount: consumedCharacters,
            latency: latency,
            kind: kind
        )
    }
}

/// Records the chunk committed by the most recent full acceptance and the field text it was
/// appended after. The coordinator stamps this on a final-chunk accept and consumes it on the next
/// generation. If the model only re-proposes `text` while the live preceding text still equals
/// `precedingText`, the host has not published our insert yet (the Chromium AX-publish race), so the
/// suggestion is dropped instead of looping accept/regenerate/accept on the last word.
struct AcceptedSuggestionTail: Equatable, Sendable {
    let text: String
    let precedingText: String
}

/// High-level suggestion states surfaced to the menu and overlay logic.
enum SuggestionDebugState: Equatable {
    case idle
    case disabled(String)
    case debouncing
    case generating
    case ready(text: String, latency: TimeInterval)
    case failed(String)

    var shortLabel: String {
        switch self {
        case .idle:
            return "Idle"
        case .disabled:
            return "Disabled"
        case .debouncing:
            return "Debouncing"
        case .generating:
            return "Generating"
        case .ready:
            return "Ready"
        case .failed:
            return "Failed"
        }
    }

    var detail: String? {
        switch self {
        case .idle:
            return "No active suggestion is currently available."
        case let .disabled(reason), let .failed(reason):
            return reason
        case .debouncing:
            return "Waiting for typing to settle."
        case .generating:
            return "Requesting a completion from the active suggestion backend."
        case .ready:
            return "Ready means Cotabby has buffered a non-empty normalized completion for this field and can render it as ghost text."
        }
    }
}

/// Geometry needed to render ghost text in the same visual line box as the host editor.
///
/// `caretRect` tells Cotabby where the current insertion point is. `inputFrameRect` gives the
/// broader editor bounds, which lets the overlay wrap overflow text back to the field's left edge
/// instead of drawing past the right edge of the text container.
struct SuggestionOverlayGeometry: Equatable, Sendable {
    let caretRect: CGRect
    let inputFrameRect: CGRect?
    let caretQuality: CaretGeometryQuality
    /// Average character width from AX child-frame sampling when available. Layout uses this as a
    /// cheap approximation for host-editor text width before falling back to local font metrics.
    let observedCharWidth: CGFloat?
    /// When `true`, the text near the caret is Right-to-Left (Arabic, Hebrew, etc.) and the ghost
    /// text overlay should appear to the left of the caret instead of the right.
    let isRightToLeft: Bool
    /// Identifies the focus session that produced this geometry. `OverlayController` keys its
    /// per-session font-size stabilization on this value, so a field switch (or focus loss) starts
    /// a fresh size baseline. Defaults to 0 for tests that do not exercise session-scoped behavior.
    let focusChangeSequence: UInt64
    /// Stable identity for the focused input field, used to scope ghost-font stabilization.
    /// Unlike `focusChangeSequence`, this does NOT change when the field resizes (e.g., a chat
    /// composer growing taller as text wraps), so the stabilizer's per-session minimum survives
    /// self-growing inputs. It DOES change when the user focuses a genuinely different field.
    /// Defaults to 0 for tests that do not exercise session-scoped behavior.
    let focusedInputIdentityKey: UInt64
    /// When `true`, the overlay is rendering a typo correction rather than a forward continuation.
    /// `OverlayController` switches to a green tint on this signal so the user can tell at a glance
    /// that pressing the accept key will replace their last word, not extend it.
    let isCorrection: Bool
    /// The host field's own text font/color, so the overlay can render ghost text that matches the
    /// field instead of always using the system font and a fixed gray. Nil falls back to defaults.
    let resolvedFieldStyle: ResolvedFieldStyle?

    init(
        caretRect: CGRect,
        inputFrameRect: CGRect?,
        caretQuality: CaretGeometryQuality,
        observedCharWidth: CGFloat?,
        isRightToLeft: Bool,
        focusChangeSequence: UInt64 = 0,
        focusedInputIdentityKey: UInt64 = 0,
        isCorrection: Bool = false,
        resolvedFieldStyle: ResolvedFieldStyle? = nil
    ) {
        self.caretRect = caretRect
        self.inputFrameRect = inputFrameRect
        self.caretQuality = caretQuality
        self.observedCharWidth = observedCharWidth
        self.isRightToLeft = isRightToLeft
        self.focusChangeSequence = focusChangeSequence
        self.focusedInputIdentityKey = focusedInputIdentityKey
        self.isCorrection = isCorrection
        self.resolvedFieldStyle = resolvedFieldStyle
    }

    /// Returns a copy with only `caretRect` replaced. Used to advance the ghost by an exact measured
    /// width on word acceptance without re-reading (and re-jittering against) a fresh AX caret.
    func withCaretRect(_ caretRect: CGRect) -> SuggestionOverlayGeometry {
        SuggestionOverlayGeometry(
            caretRect: caretRect,
            inputFrameRect: inputFrameRect,
            caretQuality: caretQuality,
            observedCharWidth: observedCharWidth,
            isRightToLeft: isRightToLeft,
            focusChangeSequence: focusChangeSequence,
            focusedInputIdentityKey: focusedInputIdentityKey,
            resolvedFieldStyle: resolvedFieldStyle
        )
    }
}

/// The overlay is intentionally modeled as data so diagnostics can reason about visibility
/// without poking into AppKit window objects directly.
///
/// `visible` carries the active `CompletionRenderMode` so the focus debug overlay, tests, and
/// presenter state-diffing can distinguish an inline ghost from a mirror card without inspecting
/// `OverlayController` internals.
enum OverlayState: Equatable {
    case hidden(reason: String)
    case visible(text: String, geometry: SuggestionOverlayGeometry, mode: CompletionRenderMode)

    var shortLabel: String {
        switch self {
        case .hidden:
            return "Hidden"
        case .visible:
            return "Visible"
        }
    }

    var detail: String {
        switch self {
        case let .hidden(reason):
            return reason
        case let .visible(text, geometry, mode):
            return "Showing \(text.count) characters near " +
                "(\(Int(geometry.caretRect.minX)), \(Int(geometry.caretRect.minY))) " +
                "using \(geometry.caretQuality.label) caret geometry (\(mode.label))."
        }
    }

    var isVisible: Bool {
        if case .visible = self {
            return true
        }

        return false
    }

    var visibleText: String? {
        guard case let .visible(text, _, _) = self else {
            return nil
        }

        return text
    }

    var visibleMode: CompletionRenderMode? {
        guard case let .visible(_, _, mode) = self else {
            return nil
        }
        return mode
    }
}

/// Errors specific to suggestion generation and normalization.
enum SuggestionClientError: LocalizedError {
    case unavailable(String)
    case unsupportedLanguageOrLocale(String)
    case generationFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .unavailable(message),
            let .unsupportedLanguageOrLocale(message),
            let .generationFailed(message):
            return message
        case .cancelled:
            return "Generation was cancelled."
        }
    }
}

private extension String {
    /// Swift `String` is a collection of extended grapheme clusters, not bytes.
    /// These helpers slice by user-visible characters so emoji and composed characters stay intact.
    /// That matters because autocomplete acceptance is a user-facing action, not a byte-level one.
    func leadingCharacters(_ count: Int) -> String {
        String(prefix(max(count, 0)))
    }

    func droppingLeadingCharacters(_ count: Int) -> String {
        String(dropFirst(max(count, 0)))
    }
}
