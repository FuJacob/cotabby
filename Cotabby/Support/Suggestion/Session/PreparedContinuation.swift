import Foundation

/// One lookahead request for the words that follow a visible word ending or correction, retained
/// only until its source word is consumed or invalidated. Keeping its plan separate from the live
/// session prevents hypothetical text from entering AX reconciliation before the editor has
/// actually published the accepted edit.
///
/// Two things progress independently: whether the user has committed the source word, and whether
/// the request has answered. The coordinator owns the engine call and the scheduling around them.
struct PreparedContinuation {
    enum Commitment: Equatable {
        /// The source word is still only an offer on screen.
        case sourceVisible
        /// The source word was accepted or typed through. `targetPublished` is set once the exact
        /// target text published while the request was still running. The publication poll stands
        /// down at that point, so nothing else will request a prediction for later edits: this
        /// request must fall back to one if it cannot show its own text.
        case committed(targetPublished: Bool)
    }

    enum Answer: Equatable {
        case running
        case ready(text: String, latency: TimeInterval)
    }

    let plan: SuggestionContinuationPlan
    let sourceSession: ActiveSuggestionSession
    private(set) var commitment: Commitment = .sourceVisible
    private(set) var answer: Answer = .running

    init(plan: SuggestionContinuationPlan, sourceSession: ActiveSuggestionSession) {
        self.plan = plan
        self.sourceSession = sourceSession
    }

    var isCommitted: Bool {
        commitment != .sourceVisible
    }

    var ownsNextPrediction: Bool {
        commitment == .committed(targetPublished: true)
    }

    var readyText: String? {
        guard case let .ready(text, _) = answer else { return nil }
        return text
    }

    func belongs(to session: ActiveSuggestionSession) -> Bool {
        sourceSession.baseContext == session.baseContext
            && sourceSession.fullText == session.fullText && sourceSession.kind == session.kind
    }

    /// Commitment changes which text is expected next; it never restarts the request, and a
    /// repeated commit must not forget that the target already published.
    mutating func markCommitted() {
        if commitment == .sourceVisible {
            commitment = .committed(targetPublished: false)
        }
    }

    /// Only a committed source has a target to publish; before that the same text on screen is
    /// still the offer.
    mutating func markTargetPublished() {
        if isCommitted {
            commitment = .committed(targetPublished: true)
        }
    }

    mutating func receive(text: String, latency: TimeInterval) {
        answer = .ready(text: text, latency: latency)
    }
}
