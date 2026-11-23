import Foundation

/// File overview:
/// Routes the keystroke stream to the inline-command controllers (the emoji picker on `:` and the
/// macro preview on `/`) and owns the two resources the input monitor exposes as single slots: the
/// active-tap capture decider and the capture-interception flag.
///
/// Why this exists: the two features use different sigils and never overlap, but the input monitor
/// has exactly one `inlineCommandKeyDecider` and one capture-interception flag. Rather than let two
/// controllers fight over those single slots, this coordinator fans `observe` out to both, sets
/// interception to "either is capturing", and routes the decider to whichever capture is open. Their
/// triggers are disjoint, so at most one is ever capturing and at most one ever claims a key.
@MainActor
final class InlineCommandCoordinator {
    private let emoji: EmojiPickerController
    private let macro: MacroController
    private let inputMonitor: any InlineCommandInputIntercepting

    init(
        emoji: EmojiPickerController,
        macro: MacroController,
        inputMonitor: any InlineCommandInputIntercepting
    ) {
        self.emoji = emoji
        self.macro = macro
        self.inputMonitor = inputMonitor
    }

    func start() {
        emoji.onCaptureStateChanged = { [weak self] in self?.updateInterception() }
        macro.onCaptureStateChanged = { [weak self] in self?.updateInterception() }
        inputMonitor.inlineCommandKeyDecider = { [weak self] keyEvent in
            self?.decide(keyEvent) ?? .notHandled
        }
        emoji.start()
        macro.start()
    }

    func stop() {
        emoji.stop()
        macro.stop()
        inputMonitor.inlineCommandKeyDecider = nil
        updateInterception()
    }

    /// First look at every keystroke, wired through `SuggestionCoordinator.inlineCommandObserver`.
    /// Returns whether either feature was involved, so the suggestion coordinator can stand down.
    @discardableResult
    func observe(_ event: CapturedInputEvent) -> Bool {
        let macroInvolved = macro.observe(event)
        let emojiInvolved = emoji.observe(event)
        updateInterception()
        return macroInvolved || emojiInvolved
    }

    private func decide(_ keyEvent: InputMonitorKeyEvent) -> InputMonitorAcceptTapDecision {
        let macroDecision = macro.decideCaptureKey(keyEvent)
        if macroDecision != .notHandled {
            return macroDecision
        }
        return emoji.decideCaptureKey(keyEvent)
    }

    private func updateInterception() {
        inputMonitor.setCaptureInterceptionActive(emoji.isCapturing || macro.isCapturing)
    }
}
