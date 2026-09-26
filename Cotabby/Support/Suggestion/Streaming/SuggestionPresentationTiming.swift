import Foundation

/// Measures the first accepted overlay presentation submission after the latest input event.
///
/// The coordinator owns this value for its lifetime and supplies monotonic timestamps. Keeping
/// the rule here makes replacement and focus invalidation testable without an event tap or a
/// window. It stores no typed text. This measures presentation submission, not a GPU frame or
/// whether a human considers the suggestion useful; the opt-in typing eval measures usefulness.
nonisolated struct SuggestionPresentationTiming {
    struct Measurement: Equatable {
        let inputKind: String
        let milliseconds: Double
    }

    /// One pending input, owned until presentation or invalidation consumes it.
    private struct PendingInput {
        let identity: FocusedInputIdentity
        let kind: String
        let time: TimeInterval
    }

    private var pending: PendingInput?

    mutating func begin(identity: FocusedInputIdentity, kind: String, at time: TimeInterval) {
        guard time.isFinite else {
            clear()
            return
        }
        pending = PendingInput(identity: identity, kind: kind, time: time)
    }

    mutating func clear() {
        pending = nil
    }

    mutating func presented(identity: FocusedInputIdentity, at time: TimeInterval) -> Measurement? {
        defer { clear() }
        guard let pending, pending.identity == identity, time.isFinite, time >= pending.time else { return nil }
        return Measurement(inputKind: pending.kind, milliseconds: (time - pending.time) * 1_000)
    }
}
