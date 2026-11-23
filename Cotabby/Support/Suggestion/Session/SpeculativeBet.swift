import Foundation

/// The one outstanding bet on text the host has not published yet.
///
/// A speculative request is built against the text Cotabby expects (a typed character, an
/// accepted chunk) before Accessibility shows it. Its generation therefore predates the live one
/// by construction, and the ordinary "generation matches" freshness rule would drop its result.
/// The bet records what was expected, so the result may be shown once the live field reads
/// exactly that, and never in a different conversation that happens to hold the same draft.
enum SpeculativeBet: Equatable {
    case idle
    /// A request is in flight, or already shown, for `expected`; the publish poll validates it.
    case awaitingPublish(expected: FocusedInputContext)
    /// The request finished before the host published `expected`. Its result cannot be shown yet
    /// (the live text still lacks the keystroke) and must not be dropped: once the publish
    /// matches, the poll stands down instead of requesting again, so a dropped result would leave
    /// that keystroke with no suggestion. The poll replays it.
    case parked(expected: FocusedInputContext, result: SuggestionResult, workID: UInt64)

    var expected: FocusedInputContext? {
        switch self {
        case .idle:
            return nil
        case let .awaitingPublish(expected), let .parked(expected, _, _):
            return expected
        }
    }

    /// Starts a new bet. A result parked for the previous bet belonged to it alone and goes with it.
    mutating func place(expecting expected: FocusedInputContext) {
        self = .awaitingPublish(expected: expected)
    }

    /// Abandons the bet, so a late result gets no exemption and a parked one is never replayed.
    mutating func clear() {
        self = .idle
    }

    /// True once the live field reads exactly what was speculated, in the same writing session.
    /// `continues`, not `==`: a surface fact one poll failed to read is not another conversation
    /// (see `FocusedInputSessionIdentity.continues`).
    func isPaidOff(by live: FocusedInputContext) -> Bool {
        isPaidOff(sessionIdentity: live.sessionIdentity, contentSignature: live.contentSignature)
    }

    func isPaidOff(by published: FocusedInputSnapshot) -> Bool {
        isPaidOff(sessionIdentity: published.sessionIdentity, contentSignature: published.contentSignature)
    }

    private func isPaidOff(sessionIdentity: FocusedInputSessionIdentity, contentSignature: String) -> Bool {
        guard let expected else { return false }
        return sessionIdentity.continues(expected.sessionIdentity) && contentSignature == expected.contentSignature
    }

    /// Whether a streamed partial of generation `generation` is the bet's own request and the live
    /// field already reads what it was built for. Requires the identical session identity, unlike
    /// `isPaidOff`.
    func coversStreamedPartial(generation: UInt64, in live: FocusedInputContext) -> Bool {
        guard let expected else { return false }
        return expected.sessionIdentity == live.sessionIdentity
            && expected.contentSignature == live.contentSignature
            && expected.generation == generation
    }

    /// Holds `result` when it is the bet's own request finishing before the publish. Returns false
    /// for any other result, which the caller then judges by the ordinary freshness rule.
    mutating func park(_ result: SuggestionResult, workID: UInt64, live: FocusedInputContext) -> Bool {
        guard let expected, result.generation == expected.generation,
              live.sessionIdentity.continues(expected.sessionIdentity) else {
            return false
        }
        self = .parked(expected: expected, result: result, workID: workID)
        return true
    }

    /// Hands back the parked result for replay. The bet itself stays placed: the replayed result
    /// still needs it to pass as current.
    mutating func takeParked() -> (result: SuggestionResult, workID: UInt64)? {
        guard case let .parked(expected, result, workID) = self else { return nil }
        self = .awaitingPublish(expected: expected)
        return (result, workID)
    }
}
