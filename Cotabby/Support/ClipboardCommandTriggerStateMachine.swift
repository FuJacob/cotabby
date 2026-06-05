import Foundation

/// File overview:
/// The pure trigger state machine for the inline `/cb` clipboard command. Unlike the value macros,
/// `/cb` is a two-stage command: typing `/cb` at a word boundary shows a compact "open" affordance
/// (the `hint`), and the accept key escalates to the full clipboard-history list (the `list`).
///
/// The `/` sigil overlaps the macro trigger, so this machine deliberately stays passive
/// (`isCapturing == false`) while the prefix is still ambiguous (`matching`): it lets the macro
/// feature own those keystrokes and only engages once the exact `/cb` command is matched. Because the
/// engaged states come first in the coordinator's participant order, the accept key routes here while
/// the macro (which has no result for "cb") cedes it. Given the same inputs it always produces the
/// same transitions, so it is fully unit testable without Accessibility, CGEvent, or UI.
struct ClipboardCommandTriggerStateMachine {
    private(set) var state: ClipboardCommandState = .idle(previousCharacter: nil)

    /// The literal command typed after the boundary `/`. Matched case-insensitively.
    private static let command = "cb"

    /// Only the visible stages count as capturing. `matching` is intentionally invisible and passive
    /// so an ambiguous `/c…` prefix stays with the macro feature until `/cb` is fully matched.
    var isCapturing: Bool {
        switch state {
        case .hint, .list:
            return true
        case .idle, .matching:
            return false
        }
    }

    mutating func reset() {
        state = .idle(previousCharacter: nil)
    }

    struct Output: Equatable {
        let actions: [ClipboardCommandAction]
        let consumesKey: Bool

        static let ignored = Output(actions: [], consumesKey: false)
    }

    /// `selectableCount` is the number of clipboard rows currently shown; it gates list navigation and
    /// commit. The hint stage ignores it (the accept key always opens the list).
    @discardableResult
    mutating func reduce(_ input: ClipboardCommandInput, selectableCount: Int) -> Output {
        switch state {
        case let .idle(previous):
            return reduceIdle(previous: previous, input: input)
        case let .matching(typed):
            return reduceMatching(typed: typed, input: input)
        case .hint:
            return reduceHint(input: input)
        case .list:
            return reduceList(input: input, selectableCount: selectableCount)
        }
    }

    private mutating func reduceIdle(previous: Character?, input: ClipboardCommandInput) -> Output {
        switch input {
        case let .character(character):
            if character == "/", Self.isBoundary(previous) {
                state = .matching(typed: "")
                return .ignored
            }
            state = .idle(previousCharacter: character)
            return .ignored
        case .backspace, .navigate, .commitKey, .escape, .focusChanged, .dismissExternally:
            state = .idle(previousCharacter: nil)
            return .ignored
        }
    }

    private mutating func reduceMatching(typed: String, input: ClipboardCommandInput) -> Output {
        switch input {
        case let .character(character):
            let next = typed + character.lowercased()
            if next == Self.command {
                state = .hint
                return Output(actions: [.openHint], consumesKey: false)
            }
            if Self.command.hasPrefix(next) {
                state = .matching(typed: next)
                return .ignored
            }
            // Diverged from `/cb` (for example a value macro like `/today`); step aside and let the
            // macro feature own the run. Nothing was shown, so there is no panel to tear down.
            state = .idle(previousCharacter: character)
            return .ignored
        case .backspace:
            if typed.isEmpty {
                // The next backspace eats the `/` itself; nothing was shown.
                state = .idle(previousCharacter: nil)
                return .ignored
            }
            state = .matching(typed: String(typed.dropLast()))
            return .ignored
        case .navigate, .commitKey, .escape, .focusChanged, .dismissExternally:
            state = .idle(previousCharacter: nil)
            return .ignored
        }
    }

    private mutating func reduceHint(input: ClipboardCommandInput) -> Output {
        switch input {
        case .commitKey:
            // The accept key escalates the affordance into the full clipboard-history list.
            state = .list
            return Output(actions: [.openList], consumesKey: true)
        case .escape:
            state = .idle(previousCharacter: nil)
            return Output(actions: [.cancel], consumesKey: true)
        case let .character(character):
            // `/cbX` is no longer the command; close the hint and let the character reach the field.
            state = .idle(previousCharacter: character)
            return Output(actions: [.cancel], consumesKey: false)
        case .backspace, .navigate, .focusChanged, .dismissExternally:
            state = .idle(previousCharacter: nil)
            return Output(actions: [.cancel], consumesKey: false)
        }
    }

    private mutating func reduceList(input: ClipboardCommandInput, selectableCount: Int) -> Output {
        switch input {
        case let .navigate(move):
            if selectableCount > 0 {
                return Output(actions: [.moveSelection(move)], consumesKey: true)
            }
            state = .idle(previousCharacter: nil)
            return Output(actions: [.cancel], consumesKey: false)
        case .commitKey:
            if selectableCount > 0 {
                state = .idle(previousCharacter: nil)
                return Output(actions: [.commit], consumesKey: true)
            }
            state = .idle(previousCharacter: nil)
            return Output(actions: [.cancel], consumesKey: false)
        case .escape:
            state = .idle(previousCharacter: nil)
            return Output(actions: [.cancel], consumesKey: true)
        case .character, .backspace, .focusChanged, .dismissExternally:
            // There is no in-list filtering, so any typing or deletion closes the list and the key
            // falls through to the field.
            state = .idle(previousCharacter: nil)
            return Output(actions: [.cancel], consumesKey: false)
        }
    }

    /// A command may begin only at a word boundary: the start of the field or after whitespace. This
    /// keeps `and/cb` and `http://cb` from opening the picker mid-word.
    private static func isBoundary(_ previous: Character?) -> Bool {
        guard let previous else { return true }
        return previous.isWhitespace
    }
}

/// The reduced keystroke vocabulary the clipboard command machine understands. The controller
/// translates raw `CapturedInputEvent`s plus focus signals into these.
enum ClipboardCommandInput: Equatable {
    case character(Character)
    case backspace
    case navigate(CommandSelectionMove)
    case commitKey
    case escape
    case focusChanged
    case dismissExternally
}

/// Side effects the controller performs after a transition. The machine stays pure; it only
/// describes what should happen.
enum ClipboardCommandAction: Equatable {
    case openHint
    case openList
    case moveSelection(CommandSelectionMove)
    case commit
    case cancel
}

/// The lifecycle states. `idle` remembers the previously typed character so the trigger can require a
/// word boundary; `matching` is the invisible, passive accumulation toward `/cb`; `hint` is the
/// compact open-affordance; `list` is the full clipboard-history picker.
enum ClipboardCommandState: Equatable {
    case idle(previousCharacter: Character?)
    case matching(typed: String)
    case hint
    case list
}
