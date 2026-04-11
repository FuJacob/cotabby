import Foundation

/// File overview:
/// Shared value types for screenshot-derived prompt augmentation. These types keep the new
/// "visual context" pipeline explicit instead of hiding it inside `SuggestionCoordinator`.
///
/// The design goal is to model screenshot context as session state, just like suggestion state.
/// That makes stale-result handling and UI diagnostics much easier to reason about.

/// Tunables for converting a screenshot into a short prompt hint.
/// These values are intentionally separate from `SuggestionConfiguration` because they govern
/// screenshot analysis, not normal text completion behavior.
struct VisualContextConfiguration: Equatable, Sendable {
    let maxImageDimension: Int
    let minRecognizedCharacterCount: Int
    let maxRecognizedCharacters: Int
    let maxSummaryTokens: Int
    let temperature: Double
    let topK: Int
    let topP: Double
    let minP: Double
    let repetitionPenalty: Double

    static let `default` = VisualContextConfiguration(
        maxImageDimension: 1600,
        minRecognizedCharacterCount: 24,
        // Keep screenshot prompts comfortably under the runtime batch decode ceiling.
        maxRecognizedCharacters: 600,
        maxSummaryTokens: 20,
        temperature: 0.07,
        topK: 40,
        topP: 0.8,
        minP: 0.05,
        repetitionPenalty: 1.05
    )
}

/// High-level lifecycle for screenshot-derived prompt context.
/// The coordinator publishes this directly so the menu can surface useful progress without
/// dumping low-level OCR or capture internals into the UI.
enum VisualContextStatus: Equatable, Sendable {
    case idle
    case capturing
    case extractingText
    case generatingSummary
    case ready
    case unavailable(String)
    case failed(String)

    var detail: String {
        switch self {
        case .idle:
            return "Waiting for a supported text input."
        case .capturing:
            return "Capturing the frontmost window."
        case .extractingText:
            return "Extracting visible text from the screenshot."
        case .generatingSummary:
            return "Generating a short prompt hint from the screenshot text."
        case .ready:
            return "Injected screenshot context is ready."
        case let .unavailable(reason), let .failed(reason):
            return reason
        }
    }
}

/// The normalized context hint eventually injected into the completion prompt.
/// This stays intentionally small because only the summary is consumed downstream today.
struct InjectedVisualContext: Equatable, Sendable {
    let summary: String
}

/// Session-scoped state for screenshot-derived context tied to one focused field.
/// This is separate from `ActiveSuggestionSession` because the screenshot context belongs to the
/// focused input session itself, not to any one individual completion result.
struct FocusedInputAugmentationSession: Equatable, Sendable {
    let sessionID: UUID
    let elementIdentifier: String
    var status: VisualContextStatus
    var injectedContext: InjectedVisualContext?
}
