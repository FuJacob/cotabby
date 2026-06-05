import Foundation

/// File overview:
/// The pure trigger state machine for the inline `:emoji:` picker (EMOJI.md §2). It owns only the
/// capture lifecycle and the live query. Selection and match results live in `EmojiPickerController`
/// because they depend on the matcher; the machine is told the current match count when it needs it.
/// Given the same inputs it always produces the same transitions, so it is fully unit testable
/// without Accessibility, CGEvent, or UI.
///
/// Deliberate divergence from EMOJI.md §2.3: ordinary query characters are NOT consumed. They flow
/// into the focused field and the controller reads the authoritative text from Accessibility at
/// commit time. This keeps the active, gating event tap out of the ordinary-typing path (the
/// issue #328 invariant that the base branch fixed) while still consuming navigation, commit, and
/// Escape keys so the picker can be driven without the foreground app seeing them.
struct EmojiTriggerStateMachine {
    private(set) var state: EmojiTriggerState = .idle(previousCharacter: nil)

    var isCapturing: Bool {
        if case .capturing = state { return true }
        return false
    }

    /// Forces the machine back to idle. The controller calls this when it aborts a capture the
    /// machine optimistically opened (for example in a secure field), and after teardown so the next
    /// `:` is evaluated from a clean slate.
    mutating func reset() {
        state = .idle(previousCharacter: nil)
    }

    /// Result of feeding one input: the side effects to run and whether the originating key should
    /// be swallowed before the focused app sees it.
    struct Output: Equatable {
        let actions: [EmojiTriggerAction]
        let consumesKey: Bool

        static let ignored = Output(actions: [], consumesKey: false)
    }

    /// `selectableMatchCount` is the number of currently displayed matches. It only affects
    /// navigation and commit, neither of which changes the query, so the controller's existing count
    /// is always valid at those moments.
    @discardableResult
    mutating func reduce(_ input: EmojiTriggerInput, selectableMatchCount: Int) -> Output {
        switch state {
        case let .idle(previousCharacter):
            return reduceIdle(previousCharacter: previousCharacter, input: input)
        case let .capturing(query):
            return reduceCapturing(query: query, input: input, selectableMatchCount: selectableMatchCount)
        }
    }

    private mutating func reduceIdle(previousCharacter: Character?, input: EmojiTriggerInput) -> Output {
        switch input {
        case let .character(character):
            if character == Self.trigger, Self.isTriggerBoundary(previousCharacter) {
                state = .capturing(query: "")
                return Output(actions: [.open(query: "")], consumesKey: false)
            }
            state = .idle(previousCharacter: character)
            return .ignored
        case .backspace, .navigate, .commitKey, .escape, .focusChanged, .dismissExternally:
            // Any non-character activity erases our knowledge of what precedes the caret, so the
            // next `:` is treated conservatively (no boundary) unless a fresh character re-establishes
            // one.
            state = .idle(previousCharacter: nil)
            return .ignored
        }
    }

    private mutating func reduceCapturing(
        query: String,
        input: EmojiTriggerInput,
        selectableMatchCount: Int
    ) -> Output {
        switch input {
        case let .character(character):
            return reduceCapturingCharacter(query: query, character: character)

        case .backspace:
            if query.isEmpty {
                // The next backspace deletes the trigger `:` itself; let it through and close.
                state = .idle(previousCharacter: nil)
                return Output(actions: [.cancel], consumesKey: false)
            }
            let shortened = String(query.dropLast())
            state = .capturing(query: shortened)
            return Output(actions: [.updateQuery(shortened)], consumesKey: false)

        case let .navigate(move):
            if selectableMatchCount > 0 {
                return Output(actions: [.moveSelection(move)], consumesKey: true)
            }
            // No matches to move through: let the arrow drive the caret and close the picker.
            state = .idle(previousCharacter: nil)
            return Output(actions: [.cancel], consumesKey: false)

        case .commitKey:
            if selectableMatchCount > 0 {
                state = .idle(previousCharacter: nil)
                return Output(actions: [.commit(.key)], consumesKey: true)
            }
            // Nothing to insert: never steal Tab or Return from the focused app.
            state = .idle(previousCharacter: nil)
            return Output(actions: [.cancel], consumesKey: false)

        case .escape:
            state = .idle(previousCharacter: nil)
            return Output(actions: [.cancel], consumesKey: true)

        case .focusChanged, .dismissExternally:
            state = .idle(previousCharacter: nil)
            return Output(actions: [.cancel], consumesKey: false)
        }
    }

    private mutating func reduceCapturingCharacter(query: String, character: Character) -> Output {
        if character == Self.trigger {
            // Mode B: the closing `:` of `:query:`. Let it reach the field; the controller replaces
            // the whole `:query:` run on the next runloop tick (EMOJI.md §3.2, §5.5).
            state = .idle(previousCharacter: nil)
            return Output(actions: [.commit(.closingColon)], consumesKey: false)
        }
        if Self.isNameCharacter(character) {
            let extended = query + String(character)
            state = .capturing(query: extended)
            return Output(actions: [.updateQuery(extended)], consumesKey: false)
        }
        // Whitespace or punctuation terminates capture without replacing anything. Preserve the
        // terminating character so a following `:` re-evaluates the boundary the same way idle does.
        state = .idle(previousCharacter: character)
        return Output(actions: [.cancel], consumesKey: false)
    }

    // MARK: - Trigger rules

    private static let trigger: Character = ":"

    /// A capture may only begin at a word boundary: the start of the field (no known preceding
    /// character) or immediately after whitespace. This keeps `http://`, `12:30`, and `foo::bar`
    /// from spuriously opening the picker.
    private static func isTriggerBoundary(_ previous: Character?) -> Bool {
        guard let previous else { return true }
        return previous.isWhitespace
    }

    /// Characters that extend an alias query. Mirrors the punctuation gemoji allows in aliases such
    /// as `+1` and `-1`.
    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "+" || character == "-"
    }
}
