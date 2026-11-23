import ApplicationServices
import SwiftUI

/// A small inline view that captures the next keypress and reports its key code, modifier mask,
/// and a display label. Installs `NSEvent` local monitors on appear and removes them on disappear
/// or capture, so no leaked monitors accumulate.
///
/// The recorder supports modifier combinations (e.g. `⇧Tab`, `⌥`+key-above-Tab). A live preview
/// of pressed modifiers is shown via `.flagsChanged` so the user sees they're holding `⌘⇧` before
/// they commit to a key.
struct KeyRecorderView: View {
    let onKeyRecorded: (CGKeyCode, ShortcutModifierMask, String) -> Void
    var onCancelled: (() -> Void)?
    /// Returns the name of the action already bound to a proposed combo, or `nil` if it's free.
    /// When it reports a conflict the recorder refuses to commit and keeps listening, so a shortcut
    /// can never be assigned to two actions at once.
    var conflictChecker: ((CGKeyCode, ShortcutModifierMask) -> String?)?
    /// A key that may be recorded as a double press instead of a single key: the Accept Word key,
    /// when recording Accept Entire Suggestion. A single press of it is still a conflict.
    var doubleTapKey: DoubleTapRecordingKey?
    var onDoubleTapRecorded: (() -> Void)?

    @State private var monitor: Any?
    @State private var recorder = KeyRecorderState()

    var body: some View {
        Text(recorder.prompt(doubleTapKey: doubleTapKey))
            .foregroundStyle(recorder.isRejected ? Color.red : .secondary)
            .onAppear { installMonitor() }
            .onDisappear { removeMonitor() }
    }

    /// The double tap is only on offer when the caller can also store it.
    private var recordableDoubleTapKey: DoubleTapRecordingKey? {
        onDoubleTapRecorded == nil ? nil : doubleTapKey
    }

    private func installMonitor() {
        removeMonitor()
        send(.modifiersChanged([]))
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [self] event in
            handle(event: event)
        }
    }

    /// Every event the monitor matches is swallowed while recording, so a press being recorded
    /// never also types into, or triggers a shortcut in, the window behind the recorder.
    private func handle(event: NSEvent) -> NSEvent? {
        switch event.type {
        case .flagsChanged:
            send(.modifiersChanged(ShortcutModifierMask(nsEventFlags: event.modifierFlags)))
        case .keyDown:
            let press = KeyRecorderState.KeyPress(
                keyCode: CGKeyCode(event.keyCode),
                modifiers: ShortcutModifierMask(nsEventFlags: event.modifierFlags),
                isRepeat: event.isARepeat,
                timestamp: event.timestamp
            )
            perform(send(.keyDown(press)), for: event)
        default:
            return event
        }
        return nil
    }

    @discardableResult
    private func send(_ input: KeyRecorderState.Input) -> KeyRecorderState.Effect? {
        recorder.handle(
            input,
            doubleTapKey: recordableDoubleTapKey,
            conflictOwner: { keyCode, modifiers in conflictChecker?(keyCode, modifiers) }
        )
    }

    private func perform(_ effect: KeyRecorderState.Effect?, for event: NSEvent) {
        guard let effect else {
            return
        }
        switch effect {
        case .cancel:
            removeMonitor()
            onCancelled?()
        case .commit(let keyCode, let modifiers):
            let label = KeyCodeLabels.label(
                for: keyCode,
                modifiers: modifiers,
                // Use `characters` ahead of `charactersIgnoringModifiers` so we still get a readable
                // glyph for keys whose first level is a dead key (e.g. `^` on German QWERTZ). When
                // both are empty, `KeyCodeLabels` falls back to a physical-position description.
                fallback: bestCharacterFallback(for: event)
            )
            removeMonitor()
            onKeyRecorded(keyCode, modifiers, label)
        case .commitDoubleTap:
            removeMonitor()
            onDoubleTapRecorded?()
        case .scheduleSecondTapTimeout(let firstTapTimestamp):
            DispatchQueue.main.asyncAfter(deadline: .now() + DoubleTapAcceptanceState.window) {
                send(.secondTapTimedOut(firstTapTimestamp: firstTapTimestamp))
            }
        }
    }

    private func bestCharacterFallback(for event: NSEvent) -> String? {
        if let ignoring = event.charactersIgnoringModifiers,
           !ignoring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ignoring
        }
        return event.characters
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

extension ShortcutModifierMask {
    /// Bridges `NSEvent.ModifierFlags` (used by the recorder's local monitor) into the same
    /// 4-bit shape we store. Mirrors `init(eventFlags:)` but for the AppKit flavour of flags.
    init(nsEventFlags: NSEvent.ModifierFlags) {
        var mask: ShortcutModifierMask = []
        if nsEventFlags.contains(.command) { mask.insert(.command) }
        if nsEventFlags.contains(.shift) { mask.insert(.shift) }
        if nsEventFlags.contains(.option) { mask.insert(.option) }
        if nsEventFlags.contains(.control) { mask.insert(.control) }
        self = mask
    }
}
