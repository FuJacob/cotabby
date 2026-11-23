import CoreGraphics
import Foundation

/// Throttles an expensive Accessibility tree walk so it runs at most once per `interval` while
/// focus stays on one field, reusing the previous walk's answer inside the window.
///
/// Two walks sit behind it, each visiting a few hundred AX nodes with several synchronous IPC round
/// trips per node:
///   - the deep caret BFS (`FocusSnapshotResolver.findDeepGeometrySource`). In Chromium editors such
///     as Gmail the focused element reports only weak primary geometry, so the walk fired on every
///     keystroke and pinned a CPU core.
///   - the Branch 2.5 static-text-run walk (`AXTextGeometryResolver.collectStaticTextRuns`), the
///     primary caret path in the same hosts. Within the window only the cheap, pure caret-placement
///     math reruns against the live text and selection, so the caret keeps tracking the typed
///     offset while the run frames can trail a reflow by up to one interval.
///
/// Keyed on `FocusTracker`'s `focusChangeSequence` rather than the AX element: Chrome recycles AX
/// node handles, so an element-identity key would miss on nearly every poll and defeat the throttle,
/// whereas the sequence is derived from the field frame and stays stable across keystrokes in one
/// field. A changed sequence is a real field switch and forces an immediate fresh walk. Only the
/// latest field is remembered, so one slot can never answer for an earlier field.
///
/// A walk that found nothing (a nil result, an empty run list) is still an answer and is reused:
/// re-walking every keystroke for a field with nothing to find is exactly the cost this removes.
///
/// A reference type so it can carry state across the value-typed `FocusSnapshotResolver`'s
/// non-mutating `resolveSnapshot`. The resolver is constructed once and retained by `FocusTracker`.
@MainActor
final class FocusSessionWalkThrottle<Value> {
    /// Which field was walked, when, and what the walk answered.
    private struct Walk {
        let focusChangeSequence: UInt64
        let walkedAt: Date
        let value: Value
    }

    /// The last walk, or nil before the first one and after `invalidate()`. One optional so the
    /// field, the time and the answer can never be partly set.
    private var lastWalk: Walk?

    // A `@MainActor` class with stored properties takes the isolated-deinit back-deploy path on
    // dealloc, which over-releases and aborts app-hosted test runs; releasing value types needs
    // no main-actor hop. Same workaround as `EmojiUsageStore` and `SystemMetricsStore`.
    nonisolated deinit {}

    /// Runs `walk` only when the throttle window has elapsed or the focused field changed; otherwise
    /// returns the previous walk's value. The window is half-open: exactly one interval later is
    /// already stale. `now` is injectable for tests.
    func value(
        focusChangeSequence: UInt64,
        interval: TimeInterval,
        now: Date = Date(),
        walk: () -> Value
    ) -> Value {
        if let lastWalk,
           lastWalk.focusChangeSequence == focusChangeSequence,
           now.timeIntervalSince(lastWalk.walkedAt) < interval {
            return lastWalk.value
        }

        let value = walk()
        lastWalk = Walk(focusChangeSequence: focusChangeSequence, walkedAt: now, value: value)
        return value
    }

    /// Drops the cached walk so the next caller pays a fresh one regardless of the window.
    ///
    /// Called after Cotabby's own synthetic insert: the cached run texts predate the inserted
    /// chunk, so mapping the post-publish caret against them lands on the pre-insert position
    /// (the accept-time jitter). Invalidation cannot fix the host's own reflow lag, but it
    /// removes the up-to-one-interval of staleness this throttle would otherwise add on top.
    func invalidate() {
        lastWalk = nil
    }
}

/// One rendered AXStaticText descendant captured by the throttled static-text-run walk.
///
/// Most hosts expose one frame per visual line. Claude instead exposes a wrapped union frame,
/// but its selected leaf still answers BoundsForRange for the character before the caret. That
/// optional character frame lets the geometry resolver recover the real line and baseline.
/// The proportional-placement classification is cached beside that geometry because deriving
/// it measures text with AppKit and should happen only during the throttled AX walk, not on
/// every live caret poll.
struct StaticTextRun {
    let text: String
    let frame: CGRect
    let caretCharacterFrame: CGRect?
    let allowsProportionalCaretPlacement: Bool

    init(
        text: String,
        frame: CGRect,
        caretCharacterFrame: CGRect? = nil,
        allowsProportionalCaretPlacement: Bool
    ) {
        self.text = text
        self.frame = frame
        self.caretCharacterFrame = caretCharacterFrame
        self.allowsProportionalCaretPlacement = allowsProportionalCaretPlacement
    }
}
