import Foundation

/// File overview:
/// A dictionary that holds at most `limit` entries and forgets the oldest-inserted one when a new
/// key would exceed that. For the small per-field measurement caches in the presentation layer,
/// which would otherwise grow by one entry per line or paragraph for the app's lifetime.
///
/// Eviction is by insertion order, not by use: replacing the value under a key that is already
/// present keeps that key's place in line. The callers' keys embed the text or line they measured,
/// so an entry is superseded by a new key long before recency of use would matter.
nonisolated struct BoundedCache<Key: Hashable, Value> {
    let limit: Int
    private var values: [Key: Value] = [:]
    private var insertionOrder: [Key] = []

    init(limit: Int) {
        precondition(limit > 0, "A bounded cache needs room for at least one entry")
        self.limit = limit
    }

    var count: Int { values.count }

    subscript(key: Key) -> Value? {
        values[key]
    }

    mutating func insert(_ value: Value, for key: Key) {
        if values[key] == nil {
            insertionOrder.append(key)
            if insertionOrder.count > limit {
                values.removeValue(forKey: insertionOrder.removeFirst())
            }
        }
        values[key] = value
    }
}
