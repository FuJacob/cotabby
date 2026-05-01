import CoreGraphics
import Foundation

/// File overview:
/// Defines the pure value types that describe Tabby's autocomplete domain:
/// configuration, generation requests, normalized model output, active suggestion sessions,
/// and overlay visibility.
///
/// This file is intentionally free of AppKit, AX, and runtime side effects so maintainers can
/// understand the core state machine without reading OS integration code first.

/// User-facing presets that bound how long one inline suggestion may be.
/// Treating this as an enum keeps the UI and prompt policy in one source of truth.
enum SuggestionWordCountPreset: String, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
    case oneToThree = "1-3"
    case threeToSeven = "3-7"
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
        case .oneToThree:
            return "Return only the next 1 to 3 words."
        case .threeToSeven:
            return "Return only the next 3 to 7 words."
        case .sevenToTwelve:
            return "Return only the next 7 to 12 words."
        case .twelveToTwenty:
            return "Return only the next 12 to 20 words."
        }
    }

    /// Token budget sized at ~1.5x the upper word bound. Tight enough to enforce the word cap
    /// while leaving room for multi-token words (contractions, proper nouns, punctuation).
    var suggestedPredictionTokenBudget: Int {
        switch self {
        case .oneToThree:
            return 5
        case .threeToSeven:
            return 11
        case .sevenToTwelve:
            return 18
        case .twelveToTwenty:
            return 30
        }
    }
}

/// User-facing indicator display mode for supported text fields.
/// This replaces the old caret-indicator boolean so Tabby can express multiple affordances
/// without smuggling extra meaning through one toggle.
enum ActivationIndicatorMode: String, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
    case hidden
    case caretAnchor
    case fieldEdgeIcon

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .hidden:
            return "None"
        case .caretAnchor:
            return "Caret"
        case .fieldEdgeIcon:
            return "Tabby Icon"
        }
    }

    var compactLabel: String {
        switch self {
        case .hidden:
            return "None"
        case .caretAnchor:
            return "Caret"
        case .fieldEdgeIcon:
            return "Tabby"
        }
    }
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
    let maxSuffixCharacters: Int
    /// Shipped first-launch default for the user's saved custom instructions.
    /// `SuggestionSettingsModel` persists the user's real preference; configuration only provides
    /// the app's starting value for a fresh install.
    let defaultCustomAIInstructions: String?
    let defaultWordCountPreset: SuggestionWordCountPreset

    /// The configuration shipped by the app today.
    /// These are product defaults, not temporary debug overrides.
    static let standard = SuggestionConfiguration(
        // Keep completions short so ghost text stays fast and easy to accept.
        maxPredictionTokens: 8,
        // Many host apps do not publish updated AX text/caret state in the same frame as typing.
        // A slightly slower debounce gives the model fresher context and avoids obvious staleness.
        debounceMilliseconds: 180,
        // Low temperature keeps inline completions stable and less likely to drift.
        temperature: 0.1,
        topK: 20,
        topP: 0.7,
        minP: 0.08,
        repetitionPenalty: 1.05,
        randomSeed: nil,
        maxPrefixWords: 50,
        // Prompt windows should stay small. Sending an entire editor buffer hurts latency with
        // little quality gain because Tabby is only completing the immediate local continuation.
        maxPrefixCharacters: 1000,
        maxSuffixCharacters: 192,
        // Seed the instructions-based mode with the current house writing guidance on first launch.
        defaultCustomAIInstructions: """
            My name is Jacob Fu. I usually write in English.
            Write in a friendly, professional and empathetic voice.
            """,
        defaultWordCountPreset: .sevenToTwelve
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
        focusChangeSequence = snapshot.focusChangeSequence
        self.generation = generation
    }

    var identity: FocusedInputIdentity {
        FocusedInputIdentity(
            elementIdentifier: elementIdentifier,
            focusChangeSequence: focusChangeSequence
        )
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
    /// Optional user-provided style guidance. We keep this separate from base product behavior so
    /// future settings/personalization work can evolve independently from prompt safety rules.
    let customAIInstructions: String?
    /// Ephemeral screen context summary injected only when available for the active text field.
    let visualContextSummary: String?
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

    init(
        baseContext: FocusedInputContext,
        fullText: String,
        consumedCharacterCount: Int = 0,
        latency: TimeInterval
    ) {
        self.baseContext = baseContext
        self.fullText = fullText
        self.consumedCharacterCount = min(max(consumedCharacterCount, 0), fullText.count)
        self.latency = latency
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
            latency: latency
        )
    }

    /// Rebuilds the session from a fully observed live editor state during reconciliation.
    /// This is useful when AX catches up after optimistic UI updates such as partial Tab accepts.
    func withConsumedCharacters(_ consumedCharacters: Int) -> ActiveSuggestionSession {
        ActiveSuggestionSession(
            baseContext: baseContext,
            fullText: fullText,
            consumedCharacterCount: consumedCharacters,
            latency: latency
        )
    }
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
            return "Ready means Tabby has buffered a non-empty normalized completion for this field and can render it as ghost text."
        }
    }
}

/// Geometry needed to render ghost text in the same visual line box as the host editor.
///
/// `caretRect` tells Tabby where the current insertion point is. `inputFrameRect` gives the
/// broader editor bounds, which lets the overlay wrap overflow text back to the field's left edge
/// instead of drawing past the right edge of the text container.
struct SuggestionOverlayGeometry: Equatable, Sendable {
    let caretRect: CGRect
    let inputFrameRect: CGRect?
    let caretQuality: CaretGeometryQuality
    /// Average character width from AX child-frame sampling when available. Layout uses this as a
    /// cheap approximation for host-editor text width before falling back to local font metrics.
    let observedCharWidth: CGFloat?
}

/// The overlay is intentionally modeled as data so diagnostics can reason about visibility
/// without poking into AppKit window objects directly.
enum OverlayState: Equatable {
    case hidden(reason: String)
    case visible(text: String, geometry: SuggestionOverlayGeometry)

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
        case let .visible(text, geometry):
            return "Showing \(text.count) characters near " +
                "(\(Int(geometry.caretRect.minX)), \(Int(geometry.caretRect.minY))) " +
                "using \(geometry.caretQuality.label) caret geometry."
        }
    }

    var isVisible: Bool {
        if case .visible = self {
            return true
        }

        return false
    }

    var visibleText: String? {
        guard case let .visible(text, _) = self else {
            return nil
        }

        return text
    }
}

/// Errors specific to suggestion generation and normalization.
enum SuggestionClientError: LocalizedError {
    case unavailable(String)
    case generationFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .unavailable(message), let .generationFailed(message):
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
