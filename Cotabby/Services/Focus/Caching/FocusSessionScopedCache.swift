import Foundation

/// Caches per-element AX reads that cannot change while focus stays in one field, keyed by
/// `FocusTracker`'s `focusChangeSequence` plus an element key.
///
/// The focus resolver re-reads several invariant attributes (secure-field markers, terminal DOM
/// classes) on every poll tick; each read is a synchronous cross-process Accessibility round trip.
/// Scoping the cache to the focus-change sequence is what makes it safe: `elementIdentifier` is
/// CFHash-based and collides across recycled AX nodes, so an identity-only cache could serve a
/// stale verdict (for example "not secure") to a different field after a focus switch. A changed
/// sequence is a real field switch and drops everything.
///
/// A reference type so it can carry state across the value-typed `FocusSnapshotResolver`'s
/// non-mutating `resolveSnapshot`, mirroring `DeepGeometryWalkThrottle` and `FieldStyleCache`.
@MainActor
final class FocusSessionScopedCache<Value> {
    private var sequence: UInt64?
    private var values: [String: Value] = [:]

    // A `@MainActor` class with stored properties takes the isolated-deinit back-deploy path on
    // dealloc, which over-releases and aborts app-hosted test runs; releasing value types needs
    // no main-actor hop. Same workaround as `EmojiUsageStore` and `SystemMetricsStore`.
    nonisolated deinit {}

    /// Returns the cached value for `key` within the current focus session, computing and storing
    /// it on first use. Entry count is bounded by the handful of candidates inspected per session.
    func value(
        forKey key: String,
        focusChangeSequence: UInt64,
        compute: () -> Value
    ) -> Value {
        if let cached = cachedValue(forKey: key, focusChangeSequence: focusChangeSequence) {
            return cached
        }

        let value = compute()
        store(value, forKey: key, focusChangeSequence: focusChangeSequence)
        return value
    }

    /// The entry stored for `key` in the current focus session, or nil when there is none.
    ///
    /// For callers whose entries can go stale *within* a session and must decide for themselves
    /// whether to reuse one or replace it with `store` (the line-margin cache re-measures a
    /// provisional first-line margin once the caret leaves that line). With an optional `Value`
    /// the result is doubly optional on purpose: `.some(nil)` is a cached "nothing found", which is
    /// different from never having looked.
    func cachedValue(forKey key: String, focusChangeSequence: UInt64) -> Value? {
        resetIfSessionChanged(focusChangeSequence)
        return values[key]
    }

    /// Stores `value` for `key` in the current focus session, replacing any earlier entry.
    func store(_ value: Value, forKey key: String, focusChangeSequence: UInt64) {
        resetIfSessionChanged(focusChangeSequence)
        values[key] = value
    }

    /// A changed sequence is a real field switch: drop every entry from the previous session.
    private func resetIfSessionChanged(_ focusChangeSequence: UInt64) {
        guard sequence != focusChangeSequence else { return }
        sequence = focusChangeSequence
        values.removeAll(keepingCapacity: true)
    }
}
