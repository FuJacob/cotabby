import Foundation

/// Throttles the deep-tree caret BFS so it runs at most once per `interval` while focus stays on one
/// field. `findDeepGeometrySource` walks up to ~200 AX nodes with several synchronous IPC round-trips
/// each; in Chromium editors (e.g. Gmail) the focused element reports only `.derived` primary
/// geometry, so the walk fired on every keystroke and pinned a CPU core. Reusing the prior deep
/// result inside the window keeps caret-source selection identical while collapsing the
/// per-keystroke AX traffic.
///
/// Keyed on `FocusTracker`'s `focusChangeSequence` rather than the AX element: Chrome recycles AX
/// node handles, so an element-identity key would miss on nearly every poll and defeat the throttle,
/// whereas the sequence is derived from the field frame and stays stable across keystrokes in one
/// field. A changed sequence is a real field switch and forces an immediate fresh walk.
///
/// A reference type so it can carry state across the value-typed `FocusSnapshotResolver`'s
/// non-mutating `resolveSnapshot`. The resolver is constructed once and retained by `FocusTracker`.
@MainActor
final class DeepGeometryWalkThrottle {
    private var lastSequence: UInt64?
    private var lastWalkAt: Date?
    private var cachedResult: CaretGeometryResult?

    /// Runs `walk` only when the throttle window has elapsed or the focused field changed; otherwise
    /// returns the previous deep result. `now` is injectable for tests.
    func result(
        focusChangeSequence: UInt64,
        interval: TimeInterval,
        now: Date = Date(),
        walk: () -> CaretGeometryResult?
    ) -> CaretGeometryResult? {
        if focusChangeSequence == lastSequence,
            let lastWalkAt,
            now.timeIntervalSince(lastWalkAt) < interval {
            return cachedResult
        }

        let result = walk()
        lastSequence = focusChangeSequence
        lastWalkAt = now
        cachedResult = result
        return result
    }

    // Mirrors FieldStyleCache: keep deallocation off the back-deployment main-actor executor
    // shim, whose StopLookupScope double-frees on macOS 26. Only test-scoped resolvers ever
    // deallocate this type.
    nonisolated deinit {}
}
