import Foundation

/// Cadence of the wait for the host to publish a keystroke to Accessibility.
///
/// The event tap sees a key before the host processes it, so a prediction requested at once would
/// be built from pre-keystroke text. The coordinator polls the focus snapshot on this schedule
/// until it moves on, and gives up at the ceiling so a silent host cannot hang the pipeline.
enum HostPublishPollSchedule {
    /// Maximum wall time to wait before generating against whatever is there. Chosen empirically:
    /// long enough to cover Chrome's slower contenteditable publish on a busy page, short enough
    /// that the user can always type ahead without the rescheduled suggestion feeling stuck.
    static let waitCeilingMilliseconds = 400

    /// Delay before the first poll. An immediate read would run inside the keystroke's own tap
    /// callback, before the host has processed the key, and always miss while still paying the
    /// full AX cost. A short first wait catches fast-publishing native apps in about 10 ms.
    static let firstIntervalMilliseconds = 6

    /// Native hosts publish a keystroke within roughly 10-40 ms, so the wait polls densely during
    /// that window. With a 30 ms step from the start, a publish that landed just after the first
    /// poll waited a further ~30 ms (live TextEdit trace: key-to-request 50 ms instead of ~20 ms).
    /// The dense phase costs a handful of ~2-3 ms AX reads per keystroke.
    static let fastIntervalMilliseconds = 8
    static let fastPhaseMilliseconds = 60

    /// Steady interval for slow Chromium hosts once the dense phase is over. Same order of
    /// magnitude as the focus poll itself (default 80 ms) but tighter, so the publish is caught
    /// promptly without burning CPU on AX queries that are themselves 5-15 ms each.
    static let steadyIntervalMilliseconds = 30

    /// How long to wait before polling again when `elapsedMilliseconds` of scheduled waiting have
    /// passed without a publish, or nil once another poll would reach the ceiling.
    static func nextInterval(afterElapsedMilliseconds elapsedMilliseconds: Int) -> Int? {
        let interval = elapsedMilliseconds < fastPhaseMilliseconds
            ? fastIntervalMilliseconds
            : steadyIntervalMilliseconds
        return elapsedMilliseconds + interval < waitCeilingMilliseconds ? interval : nil
    }
}

/// The Accessibility state captured at keystroke time, against which the host-publish poll
/// detects that the host has processed the key.
struct HostPublishBaseline: Equatable {
    let precedingText: String?
    let elementIdentifier: String?
    let selectionLocation: Int?
    /// A replacement must never be judged again against the same pre-replacement text, so its
    /// poll counts only new text. Ordinary keystrokes also accept a moved caret or a new element,
    /// for hosts that publish no observable text change.
    let requiresTextChange: Bool

    init(snapshot: FocusedInputSnapshot?, requiresTextChange: Bool) {
        precedingText = snapshot?.precedingText
        elementIdentifier = snapshot?.elementIdentifier
        selectionLocation = snapshot?.selection.location
        self.requiresTextChange = requiresTextChange
    }

    /// Whether `current` shows the host has moved past the baseline. A missing snapshot counts as
    /// a change of everything it lacks: the user left the editable field, and the prediction path
    /// that follows handles the unsupported state.
    ///
    /// After a replacement only new text counts. Chromium can hand out a new AX wrapper while the
    /// old word is still visible, and re-running the typo gate there would replace it twice.
    func hostMovedOn(to current: FocusedInputSnapshot?) -> Bool {
        let textChanged = current?.precedingText != precedingText
        let elementChanged = current?.elementIdentifier != elementIdentifier
        let selectionChanged = current?.selection.location != selectionLocation
        return textChanged || ((elementChanged || selectionChanged) && !requiresTextChange)
    }

    /// What the poll does after reading `current`, `elapsedMilliseconds` of scheduled waiting
    /// after the keystroke. A publish is checked before the ceiling, so the read that lands on the
    /// ceiling still counts a publish it observed.
    ///
    /// `awaitingPreparedTarget` holds off a publish while a committed prepared continuation names
    /// the exact text it waits for: a replacement can publish its backspaces before its insert,
    /// and those intermediate slices are not the user's edit.
    func nextStep(
        after current: FocusedInputSnapshot?,
        awaitingPreparedTarget: Bool,
        elapsedMilliseconds: Int
    ) -> HostPublishPollStep {
        if !awaitingPreparedTarget && hostMovedOn(to: current) {
            return .published
        }
        if let interval = HostPublishPollSchedule.nextInterval(afterElapsedMilliseconds: elapsedMilliseconds) {
            return .pollAgain(afterMilliseconds: interval)
        }
        return requiresTextChange ? .abandonAtCeiling : .generateAtCeiling
    }
}

/// One step of the host-publish poll.
enum HostPublishPollStep: Equatable {
    /// The host processed the key; the prediction that waited for it may run.
    case published
    /// Nothing observable changed yet.
    case pollAgain(afterMilliseconds: Int)
    /// The ceiling passed without a change. Ordinary input generates against whatever is there:
    /// a host that never publishes an observable change (a dead-key composition) would otherwise
    /// never get its next prediction.
    case generateAtCeiling
    /// The ceiling passed without the replacement's new text. Generating would judge the same
    /// stale word again and could correct it twice, so the next real input restarts prediction.
    case abandonAtCeiling
}
