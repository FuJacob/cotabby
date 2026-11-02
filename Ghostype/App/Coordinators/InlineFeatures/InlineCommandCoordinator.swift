import Foundation

/// File overview:
/// Routes the keystroke stream to the inline-command controllers (the emoji picker on `:`, the
/// macro preview on `/`, and the numbered synonym list for a selected word) and owns the two resources the input monitor exposes as single slots: the
/// active-tap capture decider and the capture-interception flag.
///
/// Why this exists: the two features use different sigils and never overlap, but the input monitor
/// has exactly one `emojiCaptureKeyDecider` and one capture-interception flag. Rather than let two
/// controllers fight over those single slots, this coordinator fans `observe` out to both, sets
/// interception to "either is capturing", and routes the decider to whichever capture is open. Their
/// triggers are disjoint, so at most one is ever capturing and at most one ever claims a key. The
/// synonym list opens on a selection rather than a sigil; it gets first look at each key, and a key it
/// claims (a digit pick or Esc) is not shown to the other two.
@MainActor
final class InlineCommandCoordinator {
    private let emoji: EmojiPickerController
    private let macro: MacroController
    private let synonyms: SynonymController
    private let inputMonitor: any EmojiInputIntercepting

    init(
        emoji: EmojiPickerController,
        macro: MacroController,
        synonyms: SynonymController,
        inputMonitor: any EmojiInputIntercepting
    ) {
        self.emoji = emoji
        self.macro = macro
        self.synonyms = synonyms
        self.inputMonitor = inputMonitor
    }

    func start() {
        emoji.onCaptureStateChanged = { [weak self] in self?.updateInterception() }
        macro.onCaptureStateChanged = { [weak self] in self?.updateInterception() }
        synonyms.onCaptureStateChanged = { [weak self] in self?.updateInterception() }
        inputMonitor.emojiCaptureKeyDecider = { [weak self] keyEvent in
            self?.decide(keyEvent) ?? .notHandled
        }
        emoji.start()
        macro.start()
        synonyms.start()
    }

    func stop() {
        emoji.stop()
        macro.stop()
        synonyms.stop()
        inputMonitor.emojiCaptureKeyDecider = nil
        updateInterception()
    }

    /// First look at every keystroke, wired through `SuggestionCoordinator`'s inline-command observer.
    /// Returns whether either feature was involved, so the suggestion coordinator can stand down.
    @discardableResult
    func observe(_ event: CapturedInputEvent) -> Bool {
        if synonyms.observe(event) {
            updateInterception()
            return true
        }
        let macroInvolved = macro.observe(event)
        let emojiInvolved = emoji.observe(event)
        updateInterception()
        return macroInvolved || emojiInvolved
    }

    private func decide(_ keyEvent: InputMonitorKeyEvent) -> InputMonitorAcceptTapDecision {
        let synonymDecision = synonyms.decideCaptureKey(keyEvent)
        if synonymDecision != .notHandled {
            return synonymDecision
        }
        let macroDecision = macro.decideCaptureKey(keyEvent)
        if macroDecision != .notHandled {
            return macroDecision
        }
        return emoji.decideCaptureKey(keyEvent)
    }

    private func updateInterception() {
        inputMonitor.setCaptureInterceptionActive(emoji.isCapturing || macro.isCapturing || synonyms.isCapturing)
    }
}
