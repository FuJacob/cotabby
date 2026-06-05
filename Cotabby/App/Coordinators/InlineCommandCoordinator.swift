import Foundation

/// One participant in the inline-command system: a feature (emoji, macro, clipboard, and later
/// entities/finder) that observes keystrokes, tracks its own capture, and decides per-key consumption
/// for the active accept tap. Behavior-shaped so the coordinator can treat every feature uniformly.
@MainActor
protocol InlineCommandParticipant: AnyObject {
    /// Whether this participant currently has an open capture.
    var isCapturing: Bool { get }
    /// Invoked when capture opens or tears down, including outside an `observe` pass (focus change,
    /// long pause, click-away), so the coordinator can recompute the shared interception flag.
    var onCaptureStateChanged: (() -> Void)? { get set }

    func start()
    func stop()
    @discardableResult func observe(_ event: CapturedInputEvent) -> Bool
    func decideCaptureKey(_ keyEvent: InputMonitorKeyEvent) -> InputMonitorAcceptTapDecision
}

extension EmojiPickerController: InlineCommandParticipant {}
extension MacroController: InlineCommandParticipant {}
extension ClipboardPickerController: InlineCommandParticipant {}

/// File overview:
/// Routes the keystroke stream to every inline-command participant and owns the two resources the
/// input monitor exposes as single slots: the active-tap capture decider and the capture-interception
/// flag.
///
/// Why this exists: the features share one keystroke stream while the input monitor has exactly one
/// `emojiCaptureKeyDecider` and one capture-interception flag. Rather than let controllers fight over
/// them, this coordinator fans `observe` out to all participants, sets interception to "any is
/// capturing", and routes the decider to the first participant that claims a key.
///
/// The emoji picker is on `:`; the macro preview and the `/cb` clipboard command both start with `/`.
/// They are NOT mutually exclusive: typing `/cb` leaves the macro capturing "cb" (which yields no
/// result, so it shows nothing and cedes the accept key) while the clipboard command shows its hint.
/// The clipboard participant is therefore ordered before the macro one so `decide` returns its
/// `.consume` for the accept key first.
@MainActor
final class InlineCommandCoordinator {
    private let participants: [any InlineCommandParticipant]
    private let inputMonitor: any EmojiInputIntercepting

    /// Participants are offered each event in array order. The clipboard command must come before the
    /// macro preview so that, while both are capturing a `/cb` run, the accept key routes to the
    /// clipboard list rather than the macro (which has no result for "cb"). `decide` returns the first
    /// non-`.notHandled` decision, so order is the disambiguation.
    init(participants: [any InlineCommandParticipant], inputMonitor: any EmojiInputIntercepting) {
        self.participants = participants
        self.inputMonitor = inputMonitor
    }

    func start() {
        for participant in participants {
            participant.onCaptureStateChanged = { [weak self] in self?.updateInterception() }
        }
        inputMonitor.emojiCaptureKeyDecider = { [weak self] keyEvent in
            self?.decide(keyEvent) ?? .notHandled
        }
        for participant in participants {
            participant.start()
        }
    }

    func stop() {
        for participant in participants {
            participant.stop()
        }
        inputMonitor.emojiCaptureKeyDecider = nil
        updateInterception()
    }

    /// First look at every keystroke, wired through `SuggestionCoordinator`'s inline-command observer.
    /// Returns whether any feature was involved, so the suggestion coordinator can stand down. Every
    /// participant is called (no short-circuit) because each maintains its own boundary state.
    @discardableResult
    func observe(_ event: CapturedInputEvent) -> Bool {
        var involved = false
        for participant in participants where participant.observe(event) {
            involved = true
        }
        updateInterception()
        return involved
    }

    private func decide(_ keyEvent: InputMonitorKeyEvent) -> InputMonitorAcceptTapDecision {
        for participant in participants {
            let decision = participant.decideCaptureKey(keyEvent)
            if decision != .notHandled {
                return decision
            }
        }
        return .notHandled
    }

    private func updateInterception() {
        inputMonitor.setCaptureInterceptionActive(participants.contains { $0.isCapturing })
    }
}
