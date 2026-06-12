import CoreGraphics
import Foundation

/// Throttles the Branch 2.5 static-text-run walk so it runs at most once per `interval` while
/// focus stays on one field. `collectStaticTextRuns` visits up to ~300 AX nodes with several
/// synchronous IPC round trips per static-text leaf; in Gmail-class Chromium editors it is the
/// primary caret path and previously re-walked on every poll tick and every keystroke.
///
/// Within the window the cached run frames are reused and only the cheap, pure caret-placement
/// math reruns against the live text and selection, so the caret keeps tracking the typed offset;
/// the frames themselves can trail a reflow by up to one interval, the same accepted tradeoff as
/// `DeepGeometryWalkThrottle`. Keyed on `focusChangeSequence` rather than the AX element because
/// Chrome recycles node handles, which would defeat an identity key (see the deep-walk throttle's
/// rationale); callers additionally restrict the throttle to the focused element so one slot can
/// never serve runs collected from a different root.
@MainActor
final class StaticTextRunWalkThrottle {
    typealias TextRun = (text: String, frame: CGRect)

    private var lastSequence: UInt64?
    private var lastWalkAt: Date?
    private var cachedRuns: [TextRun]?

    // A `@MainActor` class with stored properties takes the isolated-deinit back-deploy path on
    // dealloc, which over-releases and aborts app-hosted test runs; releasing value types needs
    // no main-actor hop. Same workaround as `EmojiUsageStore` and `SystemMetricsStore`.
    nonisolated deinit {}

    /// Drops the cached walk so the next caller pays a fresh one regardless of the window.
    ///
    /// Called after Cotabby's own synthetic insert: the cached run texts predate the inserted
    /// chunk, so mapping the post-publish caret against them lands on the pre-insert position
    /// (the accept-time jitter). Invalidation cannot fix the host's own reflow lag, but it
    /// removes the up-to-one-interval of staleness this throttle would otherwise add on top.
    func invalidate() {
        lastSequence = nil
        lastWalkAt = nil
        cachedRuns = nil
    }

    /// Runs `walk` only when the throttle window elapsed or the focused field changed; otherwise
    /// returns the previous run list (including a cached empty result). `now` is injectable for
    /// tests.
    func runs(
        focusChangeSequence: UInt64,
        interval: TimeInterval,
        now: Date = Date(),
        walk: () -> [TextRun]
    ) -> [TextRun] {
        if focusChangeSequence == lastSequence,
            let lastWalkAt,
            let cachedRuns,
            now.timeIntervalSince(lastWalkAt) < interval {
            return cachedRuns
        }

        let result = walk()
        lastSequence = focusChangeSequence
        lastWalkAt = now
        cachedRuns = result
        return result
    }
}
