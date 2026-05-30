import Foundation

/// File overview:
/// Shared value types for screenshot-derived prompt augmentation. These types keep the new
/// "visual context" pipeline explicit instead of hiding it inside `SuggestionCoordinator`.
///
/// The design goal is to model screenshot context as session state, just like suggestion state.
/// That makes stale-result handling and UI diagnostics much easier to reason about.

/// Tunables for converting a focused-input screenshot into OCR text for prompt injection.
/// These values are intentionally separate from `SuggestionConfiguration` because they govern
/// screenshot capture and OCR, not normal text completion behavior.
struct VisualContextConfiguration: Equatable, Sendable {
    let snapshotDimension: Int
    let maxImageDimension: Int
    let minRecognizedCharacterCount: Int
    let maxRecognizedCharacters: Int
    let maxSummaryCharacters: Int

    static let `default` = VisualContextConfiguration(
        // Capture a compact area around the focused field instead of an entire window.
        snapshotDimension: 500,
        // Retina screenshots may still arrive at ~2x backing scale, so keep a small OCR ceiling.
        maxImageDimension: 900,
        minRecognizedCharacterCount: 12,
        // OCR text is injected directly into the completion prompt, so keep it intentionally short.
        maxRecognizedCharacters: 2000,
        maxSummaryCharacters: 900
    )
}

/// High-level lifecycle for screenshot-derived prompt context.
/// The coordinator publishes this directly so the menu can surface useful progress without
/// dumping low-level OCR or capture internals into the UI.
nonisolated enum VisualContextStatus: Equatable, Sendable {
    case idle
    case capturing
    case extractingText
    case summarizingText
    case ready
    case unavailable(String)
    case failed(String)

    var detail: String {
        switch self {
        case .idle:
            return "Waiting for a supported text input."
        case .capturing:
            return "Capturing nearby screen content."
        case .extractingText:
            return "Extracting visible text from the screenshot."
        case .summarizingText:
            return "Summarizing visible text for context."
        case .ready:
            return "Nearby visible text is ready."
        case let .unavailable(reason), let .failed(reason):
            return reason
        }
    }
}

/// The final visual-context excerpt eventually injected into the completion prompt.
/// This may be a model-generated summary when a summarizer is configured, or bounded normalized
/// OCR text in tests/fallback wiring where no summarizer exists.
nonisolated struct VisualContextExcerpt: Equatable, Sendable {
    let text: String
}

/// Session-scoped state for screenshot-derived context tied to one focused field.
/// This is separate from `ActiveSuggestionSession` because the screenshot context belongs to the
/// focused input session itself, not to any one individual completion result.
nonisolated struct FocusedInputAugmentationSession: Equatable, Sendable {
    let sessionID: UUID
    let elementIdentifier: String
    /// Mirrors the monotonic counter from `FocusedInputSnapshot`. The coordinator compares this
    /// alongside `elementIdentifier` to avoid CFHash-recycling false positives.
    let focusChangeSequence: UInt64
    var status: VisualContextStatus
    var excerpt: VisualContextExcerpt?
}
