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
nonisolated struct VisualContextConfiguration: Equatable, Sendable {
    let snapshotDimension: Int
    let maxImageDimension: Int
    let minRecognizedCharacterCount: Int
    let maxRecognizedCharacters: Int
    let maxSummaryCharacters: Int

    static let `default` = VisualContextConfiguration(
        // Capture a wider field-centered area so OCR can see nearby labels and conversation turns.
        snapshotDimension: 700,
        // Vision's accurate mode benefits from more pixels, but OCR cost scales with pixel area
        // and a Retina capture of the 700pt strip arrives well above this cap either way. 1200
        // keeps typical 11-13pt UI text comfortably above Vision's recognition floor (the strip
        // is ~1000pt wide, so this is ~1.2 px/pt) while cutting the Vision workload ~44% versus
        // the previous 1600 cap.
        maxImageDimension: 1200,
        minRecognizedCharacterCount: 12,
        // The summarizer needs enough raw OCR to recover task, filenames, and nearby messages.
        maxRecognizedCharacters: 5000,
        // The final prompt still stays bounded even when summarization falls back to OCR.
        maxSummaryCharacters: 1500
    )
}

/// High-level lifecycle for screenshot-derived prompt context.
/// The coordinator publishes this directly so the menu can surface useful progress without
/// dumping low-level OCR or capture internals into the UI.
nonisolated enum VisualContextStatus: Equatable, Sendable {
    case idle
    case capturing
    case extractingText
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
