import Foundation

/// In-memory least-recently-used cache of translations.
///
/// Chats re-render the same messages constantly (every scroll, every capture), so translating each
/// one once and reusing it is what keeps the overlay cheap. Nothing here is ever written to disk:
/// translations are other people's messages, and they vanish when Cotabby quits.
nonisolated struct TranslationCache: Sendable {
    private struct Key: Hashable, Sendable {
        let text: String
        let target: String
    }

    private let capacity: Int
    private var values: [Key: TranslationResult] = [:]
    private var order: [Key] = []

    init(capacity: Int = 500) {
        self.capacity = max(1, capacity)
    }

    var count: Int { values.count }

    mutating func value(for text: String, target: String) -> TranslationResult? {
        let key = Key(text: text, target: target)
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    mutating func store(_ result: TranslationResult) {
        let key = Key(text: result.sourceText, target: result.targetLanguage)
        values[key] = result
        touch(key)
        while order.count > capacity {
            values[order.removeFirst()] = nil
        }
    }

    mutating func removeAll() {
        values = [:]
        order = []
    }

    private mutating func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }
}
