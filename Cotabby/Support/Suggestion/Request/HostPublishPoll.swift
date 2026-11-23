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
}
