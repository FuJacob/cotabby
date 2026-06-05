import Foundation

/// File overview:
/// The pure trigger state machine for the inline `::macro` preview. It owns only the capture
/// lifecycle and the live query; evaluation lives in `MacroEngine` because it depends on the clock,
/// locale, and rate table. Given the same inputs it always produces the same transitions, so it is
/// fully unit testable without Accessibility, CGEvent, or UI.
///
/// Deferred resolution: a single `:` at a word boundary only moves to `pendingColon` (paint nothing,
/// consume nothing). A second `:` opens the macro; a non-colon character means the colon belonged to
/// the emoji picker, so the machine steps aside. This is what lets `:` (emoji) and `::` (macro)
/// coexist without a flash, as long as the emoji picker yields its empty-query second colon.
struct MacroTriggerStateMachine {
    private(set) var state: MacroTriggerState = .idle(previousCharacter: nil)

    var isCapturing: Bool {
        if case .capturing = state { return true }
        return false
    }

    mutating func reset() {
        state = .idle(previousCharacter: nil)
    }

    struct Output: Equatable {
        let actions: [MacroTriggerAction]
        let consumesKey: Bool

        static let ignored = Output(actions: [], consumesKey: false)
    }

    /// `hasInsertableResult` only matters for `.commitKey`: it decides whether to steal the accept
    /// key (consume and commit) or let it pass through because there is nothing to insert.
    @discardableResult
    mutating func reduce(_ input: MacroTriggerInput, hasInsertableResult: Bool) -> Output {
        switch state {
        case let .idle(previous):
            return reduceIdle(previous: previous, input: input)
        case .pendingColon:
            return reducePending(input: input)
        case let .capturing(query):
            return reduceCapturing(query: query, input: input, hasInsertableResult: hasInsertableResult)
        }
    }

    private mutating func reduceIdle(previous: Character?, input: MacroTriggerInput) -> Output {
        switch input {
        case let .character(character):
            if character == ":", Self.isBoundary(previous) {
                state = .pendingColon
                return .ignored
            }
            state = .idle(previousCharacter: character)
            return .ignored
        case .backspace, .commitKey, .escape, .navigate, .focusChanged, .dismissExternally:
            state = .idle(previousCharacter: nil)
            return .ignored
        }
    }

    private mutating func reducePending(input: MacroTriggerInput) -> Output {
        switch input {
        case let .character(character):
            if character == ":" {
                state = .capturing(query: "")
                return Output(actions: [.open], consumesKey: false)
            }
            // A single colon followed by something else belongs to the emoji picker. Remember the
            // character so a following `:` re-evaluates the boundary the same way idle does.
            state = .idle(previousCharacter: character)
            return .ignored
        case .backspace, .commitKey, .escape, .navigate, .focusChanged, .dismissExternally:
            state = .idle(previousCharacter: nil)
            return .ignored
        }
    }

    private mutating func reduceCapturing(
        query: String,
        input: MacroTriggerInput,
        hasInsertableResult: Bool
    ) -> Output {
        switch input {
        case let .character(character):
            if MacroQueryGrammar.extends(character) {
                let extended = query + String(character)
                state = .capturing(query: extended)
                return Output(actions: [.updateQuery(extended)], consumesKey: false)
            }
            // Whitespace or another terminator ends capture, leaving the literal `::query` untouched.
            state = .idle(previousCharacter: character)
            return Output(actions: [.cancel], consumesKey: false)

        case .backspace:
            if query.isEmpty {
                // The next backspace eats a colon of the `::` sigil; close and let it through.
                state = .idle(previousCharacter: nil)
                return Output(actions: [.cancel], consumesKey: false)
            }
            let shortened = String(query.dropLast())
            state = .capturing(query: shortened)
            return Output(actions: [.updateQuery(shortened)], consumesKey: false)

        case .commitKey:
            state = .idle(previousCharacter: nil)
            if hasInsertableResult {
                return Output(actions: [.commit], consumesKey: true)
            }
            // Nothing to insert: never steal the accept key from the focused app.
            return Output(actions: [.cancel], consumesKey: false)

        case .escape:
            state = .idle(previousCharacter: nil)
            return Output(actions: [.cancel], consumesKey: true)

        case .navigate, .focusChanged, .dismissExternally:
            state = .idle(previousCharacter: nil)
            return Output(actions: [.cancel], consumesKey: false)
        }
    }

    /// A capture may begin only at a word boundary: the start of the field or immediately after
    /// whitespace. This keeps `1:30`, `http://`, and `foo::bar` from opening a macro.
    private static func isBoundary(_ previous: Character?) -> Bool {
        guard let previous else { return true }
        return previous.isWhitespace
    }
}

/// The reduced keystroke vocabulary the macro trigger machine understands. The controller translates
/// raw `CapturedInputEvent`s plus focus signals into these.
enum MacroTriggerInput: Equatable {
    case character(Character)
    case backspace
    case commitKey
    case escape
    case navigate
    case focusChanged
    case dismissExternally
}

/// Side effects the controller performs after a transition. The machine stays pure; it only
/// describes what should happen.
enum MacroTriggerAction: Equatable {
    case open
    case updateQuery(String)
    case commit
    case cancel
}

/// The three lifecycle states. `idle` remembers the previously typed character so the trigger can
/// require a word boundary; `pendingColon` is the deferred state after a single boundary colon.
enum MacroTriggerState: Equatable {
    case idle(previousCharacter: Character?)
    case pendingColon
    case capturing(query: String)
}

/// Characters that extend a macro query. Locale-independent on purpose: decimals are `.`, argument
/// lists use `,`, and conversions use `->`. Only the rendered output is localized, which avoids the
/// comma-decimal ambiguity a localized input grammar would create.
enum MacroQueryGrammar {
    static func extends(_ character: Character) -> Bool {
        if character.isLetter || character.isNumber {
            return true
        }
        return "+-*/^%(),.=<>".contains(character)
    }
}
