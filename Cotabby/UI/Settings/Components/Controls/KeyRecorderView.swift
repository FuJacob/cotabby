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
    @State private var liveModifiers: ShortcutModifierMask = []
    @State private var conflictMessage: String?
    /// Event timestamp of a first press of `doubleTapKey` still waiting for its second press.
    @State private var pendingFirstTapTimestamp: TimeInterval?

    var body: some View {
        Text(promptText)
            .foregroundStyle(conflictMessage == nil ? .secondary : Color.red)
            .onAppear { installMonitor() }
            .onDisappear { removeMonitor() }
    }

    private var promptText: String {
        if let conflictMessage {
            return conflictMessage
        }
        if pendingFirstTapTimestamp != nil, let doubleTapKey {
            return "Press \(doubleTapKey.label) again…"
        }
        let glyphs = KeyCodeLabels.modifierGlyphs(liveModifiers)
        return glyphs.isEmpty ? "Press a key…" : "\(glyphs) + key…"
    }

    private func installMonitor() {
        removeMonitor()
        liveModifiers = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [self] event in
            handle(event: event)
        }
    }

    private func handle(event: NSEvent) -> NSEvent? {
        if event.type == .flagsChanged {
            liveModifiers = ShortcutModifierMask(nsEventFlags: event.modifierFlags)
            return nil
        }

        guard event.type == .keyDown else { return event }

        let keyCode = CGKeyCode(event.keyCode)
        let modifiers = ShortcutModifierMask(nsEventFlags: event.modifierFlags)

        // Plain Escape stays the universal "get me out" affordance. With any modifier held,
        // Escape becomes a bindable shortcut (e.g. `⌘Escape`) instead of cancelling — so users
        // who want it can still reach it.
        if keyCode == 53, modifiers.isEmpty {
            removeMonitor()
            onCancelled?()
            return nil
        }

        if let doubleTapKey, onDoubleTapRecorded != nil,
           keyCode == doubleTapKey.keyCode, modifiers == doubleTapKey.modifiers {
            return handleDoubleTapCandidate(event: event, key: doubleTapKey)
        }
        pendingFirstTapTimestamp = nil

        // Any other key is fair game. The pipeline is key-agnostic: `InputMonitor.classify`
        // matches the bound shortcut before its behavioral branches, and acceptance only
        // consumes the key while a suggestion is visible (otherwise it passes through and does
        // its normal job). So even Return/Delete or `⌘V` are safe to bind — they only intercept
        // in the moment a suggestion is showing.
        // Reject a combo that another action already owns. Staying in recording mode (rather than
        // committing or cancelling) lets the user immediately try a different key, and the red
        // prompt explains why the press was ignored.
        if let conflict = conflictChecker?(keyCode, modifiers) {
            conflictMessage = "Already used by \(conflict). Try another key."
            return nil
        }

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
        return nil
    }

    /// The first press waits up to `DoubleTapAcceptanceState.window` for a second one, the same
    /// window acceptance uses, so a pair that records here is a pair that works while typing. If no
    /// second press comes, the press is reported as the usual conflict, with a pointer to the
    /// double tap so the gesture is discoverable from the error.
    private func handleDoubleTapCandidate(event: NSEvent, key: DoubleTapRecordingKey) -> NSEvent? {
        // Holding the key auto-repeats; that is one long press, not a double tap.
        guard !event.isARepeat else { return nil }

        let timestamp = event.timestamp
        if let first = pendingFirstTapTimestamp, timestamp - first <= DoubleTapAcceptanceState.window {
            pendingFirstTapTimestamp = nil
            removeMonitor()
            onDoubleTapRecorded?()
            return nil
        }

        pendingFirstTapTimestamp = timestamp
        conflictMessage = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + DoubleTapAcceptanceState.window) {
            // Only the press that scheduled this timeout may turn into an error.
            guard pendingFirstTapTimestamp == timestamp else { return }
            pendingFirstTapTimestamp = nil
            let owner = conflictChecker?(key.keyCode, key.modifiers) ?? "another shortcut"
            conflictMessage = "Already used by \(owner). Press it twice quickly for a double tap."
        }
        return nil
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

/// The key a recorder may accept as a double press, with the label shown while it waits.
struct DoubleTapRecordingKey: Equatable {
    let keyCode: CGKeyCode
    let modifiers: ShortcutModifierMask
    let label: String
}
