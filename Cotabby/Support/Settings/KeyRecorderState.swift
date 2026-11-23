import CoreGraphics
import Foundation

/// The key a recorder may accept as a double press, with the label shown while it waits.
struct DoubleTapRecordingKey: Equatable {
    let keyCode: CGKeyCode
    let modifiers: ShortcutModifierMask
    let label: String
}

/// Pure state machine behind `KeyRecorderView`: what a shortcut recorder does with each key event.
///
/// The view owns the `NSEvent` monitor and the timer and feeds events in; this type decides whether
/// a press commits, cancels, is refused, or starts waiting for the second half of a double tap.
/// Keeping the rules here, away from AppKit, is what lets the double-tap window, auto-repeat and
/// stale-timeout handling be tested without synthesizing key events.
struct KeyRecorderState: Equatable {
    enum Phase: Equatable {
        case listening
        /// A first press of the double-tap key is waiting for its second. The timestamp identifies
        /// that press, so only the timeout it scheduled may end the wait.
        case awaitingSecondTap(firstTapTimestamp: TimeInterval)
        /// The last press was refused. The recorder keeps listening so another key can be tried
        /// straight away; the message says why the press was ignored.
        case rejected(message: String)
    }

    struct KeyPress: Equatable {
        let keyCode: CGKeyCode
        let modifiers: ShortcutModifierMask
        let isRepeat: Bool
        /// Event timestamp (seconds since boot), the clock the double-tap window is measured on.
        let timestamp: TimeInterval
    }

    enum Input: Equatable {
        case modifiersChanged(ShortcutModifierMask)
        case keyDown(KeyPress)
        case secondTapTimedOut(firstTapTimestamp: TimeInterval)
    }

    /// What the view must do after an input. `nil` means the event was absorbed with no side effect.
    enum Effect: Equatable {
        case cancel
        case commit(keyCode: CGKeyCode, modifiers: ShortcutModifierMask)
        case commitDoubleTap
        /// Call back with `.secondTapTimedOut` for this press once the double-tap window has passed.
        case scheduleSecondTapTimeout(firstTapTimestamp: TimeInterval)
    }

    static let escapeKeyCode: CGKeyCode = 53

    private(set) var phase: Phase = .listening
    /// Modifiers currently held, previewed in the prompt so the user sees `⌘⇧` before committing.
    private(set) var liveModifiers: ShortcutModifierMask = []

    var isRejected: Bool {
        if case .rejected = phase {
            return true
        }
        return false
    }

    /// - Parameters:
    ///   - doubleTapKey: The key that may be recorded as a double press, or `nil` when this
    ///     recorder does not offer one. A single press of it is still a conflict.
    ///   - conflictOwner: Names the action already bound to a combination, or `nil` if it is free.
    mutating func handle(
        _ input: Input,
        doubleTapKey: DoubleTapRecordingKey?,
        conflictOwner: (CGKeyCode, ShortcutModifierMask) -> String?
    ) -> Effect? {
        switch input {
        case .modifiersChanged(let modifiers):
            liveModifiers = modifiers
            return nil

        case .keyDown(let press):
            return handleKeyDown(press, doubleTapKey: doubleTapKey, conflictOwner: conflictOwner)

        case .secondTapTimedOut(let firstTapTimestamp):
            // Only the press that scheduled this timeout may turn into an error: a later press
            // either completed the pair or restarted the wait under its own timestamp.
            guard phase == .awaitingSecondTap(firstTapTimestamp: firstTapTimestamp) else {
                return nil
            }
            let owner = doubleTapKey.flatMap { conflictOwner($0.keyCode, $0.modifiers) } ?? "another shortcut"
            phase = .rejected(message: "Already used by \(owner). Press it twice quickly for a double tap.")
            return nil
        }
    }

    func prompt(doubleTapKey: DoubleTapRecordingKey?) -> String {
        switch phase {
        case .rejected(let message):
            return message
        case .awaitingSecondTap:
            if let doubleTapKey {
                return "Press \(doubleTapKey.label) again…"
            }
        case .listening:
            break
        }
        let glyphs = KeyCodeLabels.modifierGlyphs(liveModifiers)
        return glyphs.isEmpty ? "Press a key…" : "\(glyphs) + key…"
    }

    private mutating func handleKeyDown(
        _ press: KeyPress,
        doubleTapKey: DoubleTapRecordingKey?,
        conflictOwner: (CGKeyCode, ShortcutModifierMask) -> String?
    ) -> Effect? {
        // Plain Escape stays the universal "get me out" affordance. With any modifier held, Escape
        // is a bindable shortcut (e.g. `⌘Escape`) instead, so users who want it can still reach it.
        if press.keyCode == Self.escapeKeyCode, press.modifiers.isEmpty {
            return .cancel
        }

        if let doubleTapKey, press.keyCode == doubleTapKey.keyCode, press.modifiers == doubleTapKey.modifiers {
            return handleDoubleTapCandidate(press)
        }

        // Any other key is fair game, even Return, Delete or `⌘V`: acceptance only consumes the
        // bound key while a suggestion is visible and otherwise lets it do its normal job. A
        // combination another action owns is refused rather than committed, so one shortcut can
        // never be assigned to two actions.
        if let owner = conflictOwner(press.keyCode, press.modifiers) {
            phase = .rejected(message: "Already used by \(owner). Try another key.")
            return nil
        }
        phase = .listening
        return .commit(keyCode: press.keyCode, modifiers: press.modifiers)
    }

    /// The first press waits up to `DoubleTapAcceptanceState.window` for a second one, the same
    /// window acceptance uses, so a pair that records here is a pair that works while typing. If no
    /// second press comes, the timeout reports the press as the usual conflict, with a pointer to
    /// the double tap so the gesture is discoverable from the error.
    private mutating func handleDoubleTapCandidate(_ press: KeyPress) -> Effect? {
        // Holding the key auto-repeats; that is one long press, not a double tap.
        guard !press.isRepeat else {
            return nil
        }

        if case .awaitingSecondTap(let firstTapTimestamp) = phase,
           press.timestamp - firstTapTimestamp <= DoubleTapAcceptanceState.window {
            phase = .listening
            return .commitDoubleTap
        }

        phase = .awaitingSecondTap(firstTapTimestamp: press.timestamp)
        return .scheduleSecondTapTimeout(firstTapTimestamp: press.timestamp)
    }
}
