import CoreGraphics

/// File overview:
/// The hand-off between the two event taps for one inline-command key. The listen-only observer
/// sees a key first and runs the trigger machine, but it cannot swallow the event; the active tap
/// can swallow it but must answer synchronously. So the observer pass records its verdict here and
/// the active tap's decider reads it back for the same key.
struct InlineCaptureKeyDecision: Equatable {
    let keyCode: CGKeyCode
    let consume: Bool

    /// The verdict for `keyEvent`, or `nil` when this decision was recorded for a different key.
    /// The key-code match keeps a stale verdict from being applied to a later key if the decider
    /// is ever consulted without a preceding observer pass.
    func tapDecision(for keyEvent: InputMonitorKeyEvent) -> InputMonitorAcceptTapDecision? {
        guard keyCode == keyEvent.keyCode else {
            return nil
        }
        return consume ? .consume : .passThrough
    }
}
