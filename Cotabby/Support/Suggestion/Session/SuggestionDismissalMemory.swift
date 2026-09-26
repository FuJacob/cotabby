import Foundation

/// Bounded ephemeral memory of explicit dismissals, owned by the coordinator. Generation and
/// anchor-cache restoration both consult it so Escape remains meaningful through focus polling
/// and small type-through edits. It never learns from mere non-acceptance or persists user text.
nonisolated struct SuggestionDismissalMemory {
    private struct Entry {
        let identityKey: UInt64
        let preceding: String
        let trailing: String
        let target: String
        let expiresAt: TimeInterval
    }
    private var entries: [Entry] = []

    mutating func record(
        identityKey: UInt64, precedingText: String, trailingText: String,
        completion: String, at time: TimeInterval
    ) {
        guard !completion.isEmpty else { return }
        let preceding = String(precedingText.suffix(256))
        entries.removeAll { $0.expiresAt <= time }
        entries.append(Entry(identityKey: identityKey, preceding: preceding,
                             trailing: String(trailingText.prefix(192)),
                             target: preceding + Self.firstFragment(completion), expiresAt: time + 15))
        entries = Array(entries.suffix(8))
    }

    func suppresses(identityKey: UInt64, precedingText: String, trailingText: String,
                    completion: String, at time: TimeInterval) -> Bool {
        entries.contains { entry in
            guard entry.expiresAt > time, entry.identityKey == identityKey,
                  entry.trailing == String(trailingText.prefix(192)) else { return false }
            // Locate the original bounded anchor even if a few more characters have been typed.
            guard let anchor = precedingText.range(of: entry.preceding, options: .backwards),
                  precedingText.distance(from: anchor.upperBound, to: precedingText.endIndex) <= 64 else { return false }
            let live = String(precedingText[anchor.lowerBound...])
            guard entry.target.hasPrefix(live) else { return false }
            let proposed = live + Self.firstFragment(completion)
            return proposed.hasPrefix(entry.target) || entry.target.hasPrefix(proposed)
        }
    }

    private static func firstFragment(_ text: String) -> String {
        let leading = text.prefix(while: { $0.isWhitespace })
        let word = text.dropFirst(leading.count).prefix(while: { !$0.isWhitespace })
        return String((leading + word).prefix(128))
    }
}
