import Foundation

/// One request's bounded lookahead, owned by `SuggestionCoordinator` until delivery or cancellation.
///
/// Key events arrive before Accessibility publishes the edit. This value records only direct
/// appends, tolerates those still-unpublished characters, and trims them from model output only
/// after the live field confirms the exact edit. It never inserts text or owns a task. Keeping
/// this rule pure lets tests exercise Unicode offsets, stale fields, and a model falling behind
/// without an event tap or a running inference engine.
nonisolated struct TypingPredictionCandidate {
    static let catchUpWindow: TimeInterval = 0.15
    static let publicationWindow: TimeInterval = 0.4
    static let maximumTypedCharacters = 64

    let context: FocusedInputContext
    private let requiresInitialPrediction: Bool
    private(set) var typedText = ""
    private(set) var latestResult: SuggestionResult?
    private(set) var isFinal = false
    private(set) var lastInputAt: TimeInterval?
    private var behindSince: TimeInterval?

    init(context: FocusedInputContext, requiresInitialPrediction: Bool = false) {
        self.context = context
        self.requiresInitialPrediction = requiresInitialPrediction
    }

    /// Accepts a host observation along the exact append path, including an older published
    /// prefix while keys are in transit. Selection offsets use UTF-16 because AX does too.
    func accepts(_ snapshot: FocusedInputSnapshot) -> Bool {
        guard !snapshot.isSecure, snapshot.selection.length == 0,
              SuggestionContinuationPlan.sameFocusedField(snapshot, context: context),
              snapshot.trailingText == context.trailingText,
              snapshot.precedingText.hasPrefix(context.precedingText),
              (context.precedingText + typedText).hasPrefix(snapshot.precedingText) else { return false }
        let published = snapshot.precedingText.utf16.count - context.precedingText.utf16.count
        return snapshot.selection.location == context.selection.location + published
    }

    func isPublished(in snapshot: FocusedInputSnapshot) -> Bool {
        accepts(snapshot) && snapshot.precedingText == context.precedingText + typedText
    }

    /// A short grace period lets the first tokens catch up with typing. It starts at the first
    /// uncovered key, not the latest one, so continuous typing cannot postpone a fresh request.
    mutating func append(_ characters: String, in snapshot: FocusedInputSnapshot, at time: TimeInterval) -> Bool {
        guard time.isFinite, accepts(snapshot), !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              typedText.count + characters.count <= Self.maximumTypedCharacters,
              behindSince.map({ time < $0 + Self.catchUpWindow }) ?? true else { return false }
        let next = typedText + characters
        let prediction = latestResult?.text ?? ""
        // A backend that buffers its first output cannot validate a blind lookahead bet in the
        // short catch-up window. Restart from the new caret immediately instead of paying that
        // window and then the full generation latency. Once actual text arrives, ordinary matching
        // type-through and bounded catch-up still apply.
        guard !requiresInitialPrediction || !prediction.isEmpty else { return false }
        guard prediction.hasPrefix(next) || (!isFinal && next.hasPrefix(prediction)) else { return false }
        typedText = next
        lastInputAt = time
        if prediction.hasPrefix(next) {
            behindSince = nil
        } else if behindSince == nil {
            behindSince = time
        }
        return true
    }

    /// Out-of-order partial callbacks may be shorter than a newer snapshot. Ignore those;
    /// the final result is authoritative and must still agree with everything the user typed.
    mutating func receive(_ result: SuggestionResult, final: Bool) -> Bool {
        guard result.generation == context.generation, !isFinal else { return false }
        if !final, let latestResult, !result.text.hasPrefix(latestResult.text) { return true }
        guard result.text.hasPrefix(typedText) || (!final && typedText.hasPrefix(result.text)) else { return false }
        latestResult = result
        isFinal = final
        if result.text.hasPrefix(typedText) { behindSince = nil }
        return true
    }

    /// Deadline for work that is waiting on either the model or the host. A nil deadline means
    /// the prediction covers all typed characters and AX has confirmed them, so it can finish.
    func expiration(in snapshot: FocusedInputSnapshot) -> TimeInterval? {
        let modelDeadline = behindSince.map { $0 + Self.catchUpWindow }
        let hostDeadline = isPublished(in: snapshot) ? nil : lastInputAt.map { $0 + Self.publicationWindow }
        return [modelDeadline, hostDeadline].compactMap { $0 }.min()
    }

    func rebased(_ result: SuggestionResult, in snapshot: FocusedInputSnapshot,
                 generation: UInt64) -> SuggestionResult? {
        guard result.generation == context.generation, isPublished(in: snapshot),
              result.text.hasPrefix(typedText) else { return nil }
        return SuggestionResult(generation: generation, rawText: result.rawText,
            text: String(result.text.dropFirst(typedText.count)), latency: result.latency,
            suppressionReason: result.suppressionReason)
    }
}
