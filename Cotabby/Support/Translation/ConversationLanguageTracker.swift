import Foundation

/// Remembers which language each conversation is in, so a reply can be offered in it.
///
/// The incoming-message reader reports the language of the lowest (most recent) translated message
/// in a chat window; the reply controller asks for it when the user starts typing in that window.
/// Conversations are keyed by app plus window title, which in chat apps is the contact or channel
/// name. Kept in memory only and capped, like the translation cache.
nonisolated struct ConversationLanguageTracker: Sendable {
    private struct Entry: Sendable {
        let language: String
        let updatedAt: Date
    }

    private let capacity: Int
    private var entries: [String: Entry] = [:]

    init(capacity: Int = 100) {
        self.capacity = max(1, capacity)
    }

    static func key(bundleIdentifier: String, windowTitle: String?) -> String {
        "\(bundleIdentifier)|\(windowTitle ?? "")"
    }

    mutating func record(language: String, for key: String, at date: Date = Date()) {
        entries[key] = Entry(language: language, updatedAt: date)
        if entries.count > capacity, let oldest = entries.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key {
            entries[oldest] = nil
        }
    }

    func language(for key: String) -> String? {
        entries[key]?.language
    }

    mutating func removeAll() {
        entries = [:]
    }
}
