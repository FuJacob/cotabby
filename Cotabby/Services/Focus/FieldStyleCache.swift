import Foundation

/// Caches the resolved field text style per focused element so the `AXAttributedStringForRange`
/// read happens once per field, not on every focus poll.
///
/// Reading per-character font/color is a synchronous cross-process Accessibility call. The focus
/// resolver runs many times per second while focus stays on one field, so re-reading every poll
/// would add avoidable main-thread latency on the hot path. Keying on element identity collapses
/// that to one read per field. A nil result (host exposes no style) is cached too, so a plain field
/// is not re-probed on every poll.
///
/// A reference type so it can carry state across the value-typed `FocusSnapshotResolver`'s
/// non-mutating `resolveSnapshot`, mirroring `DeepGeometryWalkThrottle`. The resolver is constructed
/// once and retained by `FocusTracker`.
@MainActor
final class FieldStyleCache {
    private var key: String?
    private var style: ResolvedFieldStyle?

    /// Returns the cached style when `key` matches the last resolution, otherwise resolves once and
    /// caches the result (including nil).
    func style(forKey key: String, resolve: () -> ResolvedFieldStyle?) -> ResolvedFieldStyle? {
        if key == self.key {
            return style
        }

        let resolved = resolve()
        self.key = key
        style = resolved
        return resolved
    }

    // Stored state is plain value types, safe to release anywhere. The nonisolated deinit keeps
    // deallocation off the back-deployment main-actor executor shim, whose StopLookupScope
    // double-frees on macOS 26 (see InputSuppressionController). Production's single long-lived
    // instance never deallocates; test-scoped resolvers do.
    nonisolated deinit {}
}
