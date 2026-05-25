import ApplicationServices
import Foundation

/// File overview:
/// Defines the small, semantic input-event vocabulary that the rest of Tabby uses.
/// `InputMonitor` translates raw global keyboard events into these values so the suggestion
/// pipeline can reason about intent such as "text changed" or "caret moved" instead of
/// platform-specific key codes.
struct CapturedInputEvent: Equatable {
    /// This enum is intentionally smaller than the raw CGEvent universe.
    /// A reduced vocabulary keeps the suggestion state machine easier to reason about and test.
    enum Kind: String, Equatable {
        case acceptance
        case fullAcceptance
        case textMutation
        case navigation
        case shortcutMutation
        case dismissal
        case other
    }

    let kind: Kind
    let keyCode: CGKeyCode
    let characters: String
    let flags: CGEventFlags

    var shouldSchedulePrediction: Bool {
        switch kind {
        case .textMutation, .shortcutMutation:
            return true
        default:
            return false
        }
    }

    var shouldClearSuggestion: Bool {
        switch kind {
        case .textMutation, .navigation, .shortcutMutation, .dismissal:
            return true
        case .acceptance, .fullAcceptance, .other:
            return false
        }
    }
}
