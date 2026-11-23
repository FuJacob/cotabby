import SwiftUI

/// File overview:
/// Plays a `DemoTypingTimeline` into a view's phase state. The onboarding demos share this one
/// loop so their pacing rules (when to sleep, when to stop) cannot drift apart; each demo supplies
/// only its timeline and how a phase looks.
///
/// Call it from a `.task`: SwiftUI cancels the task when the view leaves the hierarchy, and the
/// loop checks for cancellation after every sleep so a hidden demo stops writing state promptly.
@MainActor
enum DemoTypingPlayer {
    /// Loops until cancelled. `characterCount` is read at the top of every loop so a demo that
    /// rotates through phrases types the right length each time. `onLoopReset` runs right after the
    /// field has been cleared, which is the one moment a demo can swap its phrase unseen.
    static func play(
        _ timeline: DemoTypingTimeline,
        characterCount: () -> Int,
        onLoopReset: () -> Void = {},
        setPhase: (DemoTypingPhase) -> Void
    ) async {
        if timeline.startDelayMilliseconds > 0 {
            await sleep(milliseconds: timeline.startDelayMilliseconds)
            if Task.isCancelled { return }
        }

        while !Task.isCancelled {
            let steps = timeline.loop(characterCount: characterCount())
            for (index, step) in steps.enumerated() {
                if let duration = step.animationDuration {
                    withAnimation(.easeInOut(duration: duration)) { setPhase(step.phase) }
                } else {
                    setPhase(step.phase)
                }
                if index == steps.count - 1 {
                    onLoopReset()
                }
                await sleep(milliseconds: step.holdMilliseconds)
                if Task.isCancelled { return }
            }
        }
    }

    /// Cancellation surfaces as an early return from the sleep, which callers detect through
    /// `Task.isCancelled`; there is nothing to recover from, so the thrown error is dropped.
    static func sleep(milliseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
}
