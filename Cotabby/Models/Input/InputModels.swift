import ApplicationServices
import CoreGraphics
import Foundation

/// File overview:
/// Defines the small, semantic input-event vocabulary that the rest of Cotabby uses.
/// `InputMonitor` translates raw global keyboard events into these values so the suggestion
/// pipeline can reason about intent such as "text changed" or "caret moved" instead of
/// platform-specific key codes.

/// Normalized representation of the four modifier keys a Cotabby shortcut can require.
///
/// We don't reuse `CGEventFlags` directly because it carries unrelated bits — caps lock,
/// numeric pad, secondary fn, device-specific flags — that we don't want to participate in
/// shortcut equality. Reducing to a 4-bit mask gives unambiguous storage and comparison.
struct ShortcutModifierMask: OptionSet, Hashable {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    static let command = ShortcutModifierMask(rawValue: 1 << 0)
    static let shift = ShortcutModifierMask(rawValue: 1 << 1)
    static let option = ShortcutModifierMask(rawValue: 1 << 2)
    static let control = ShortcutModifierMask(rawValue: 1 << 3)

    /// Reduces a raw `CGEventFlags` to just the four modifier bits we honor. Anything else
    /// in `flags` (caps lock, fn, numeric pad markers) is intentionally discarded.
    init(eventFlags: CGEventFlags) {
        var mask: ShortcutModifierMask = []
        if eventFlags.contains(.maskCommand) { mask.insert(.command) }
        if eventFlags.contains(.maskShift) { mask.insert(.shift) }
        if eventFlags.contains(.maskAlternate) { mask.insert(.option) }
        if eventFlags.contains(.maskControl) { mask.insert(.control) }
        self = mask
    }
}

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
