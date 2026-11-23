import Foundation

/// Normalization shared by the user-editable tag lists (custom rules, languages). Every tag ends up
/// in the prompt, so the caps protect the local model's limited context budget and guard against
/// pasted essays regardless of which editor or import path produced the list.
nonisolated enum BoundedTagList {
    /// Trims, drops empties, truncates over-long tags, de-duplicates case-insensitively (keeping
    /// the first occurrence and its original casing), and caps the count.
    static func normalize(_ tags: [String], maxCount: Int, maxLength: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let bounded = String(trimmed.prefix(maxLength))
            let key = bounded.lowercased()
            guard seen.insert(key).inserted else { continue }

            result.append(bounded)
            if result.count >= maxCount { break }
        }

        return result
    }
}
