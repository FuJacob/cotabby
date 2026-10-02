import Foundation

/// Converts a Cotypist typing-history export into Cotabby history records.
///
/// Cotypist keeps its history in an encrypted database with no export button; the user's decrypted
/// copy is a JSON array of `user_inputs` rows (`textUpToCursor`, `textAfterCursor`,
/// `appBundleIdentifier`, `domain`, `createdAt`, ...). This type only maps that shape: it does no
/// file or Keychain access, so it is pure and testable.
///
/// Cotypist stores a new row each time it snapshots the same field, so one email can appear dozens
/// of times as it grows. Rows are grouped by app plus the opening of the text, and only the longest
/// (most complete) version of each is kept; otherwise retrieval would return near-copies and phrase
/// counts would be inflated by repetition.
nonisolated enum CotypistExportImporter {
    enum ImportError: Error, Equatable, LocalizedError {
        case unrecognizedFormat

        var errorDescription: String? {
            "This file isn't a Cotypist user_inputs export (a JSON list of typing-history rows)."
        }
    }

    private struct Row: Decodable {
        let createdAt: String?
        let updatedAt: String?
        let appBundleIdentifier: String?
        let textUpToCursor: String?
        let textAfterCursor: String?
        let domain: String?
    }

    /// Texts shorter than this after scrubbing are fragments ("ok", "?") with nothing to learn.
    static let minimumCharacters = 20
    private static let groupingPrefixLength = 40

    static func records(fromExport data: Data) throws -> [TypingHistoryRecord] {
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else {
            throw ImportError.unrecognizedFormat
        }
        guard rows.isEmpty || rows.contains(where: { $0.textUpToCursor != nil }) else {
            throw ImportError.unrecognizedFormat
        }

        var longestByGroup: [String: TypingHistoryRecord] = [:]
        for row in rows {
            let (text, typedLength) = TypingHistoryScrubber.scrub(
                before: row.textUpToCursor ?? "", after: row.textAfterCursor ?? ""
            )
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumCharacters else { continue }
            let bundleIdentifier = normalizedBundleIdentifier(row.appBundleIdentifier)
            let createdAt = parseDate(row.createdAt) ?? Date(timeIntervalSince1970: 0)
            let record = TypingHistoryRecord(
                id: UUID(),
                bundleIdentifier: bundleIdentifier,
                domain: normalizedDomain(row.domain),
                createdAt: createdAt,
                updatedAt: parseDate(row.updatedAt) ?? createdAt,
                text: text,
                source: .imported,
                typedLength: typedLength
            )
            let key = bundleIdentifier + "\u{1F}" + String(text.prefix(groupingPrefixLength)).lowercased()
            if let existing = longestByGroup[key], existing.text.count >= text.count { continue }
            longestByGroup[key] = record
        }
        return droppingEarlierSnapshots(Array(longestByGroup.values)).sorted { $0.createdAt < $1.createdAt }
    }

    /// A field's early snapshots can be shorter than the grouping prefix ("Hi Arnaud, the POC is
    /// read"), so they land in their own group. Within each app, drop any text that is the start of
    /// a longer kept text: it is the same writing, caught before it was finished.
    private static func droppingEarlierSnapshots(_ records: [TypingHistoryRecord]) -> [TypingHistoryRecord] {
        var kept: [TypingHistoryRecord] = []
        for (_, appRecords) in Dictionary(grouping: records, by: \.bundleIdentifier) {
            var keptInApp: [TypingHistoryRecord] = []
            for record in appRecords.sorted(by: { $0.text.count > $1.text.count })
            where !keptInApp.contains(where: { $0.text.hasPrefix(record.text) }) {
                keptInApp.append(record)
            }
            kept.append(contentsOf: keptInApp)
        }
        return kept
    }

    /// Placeholder for rows Cotypist could not attribute to an app ("unknown.bundle" in its export).
    static let unknownBundleIdentifier = "unknown"

    private static func normalizedBundleIdentifier(_ identifier: String?) -> String {
        guard let identifier = identifier?.trimmingCharacters(in: .whitespaces), !identifier.isEmpty,
              identifier != "unknown.bundle", identifier != unknownBundleIdentifier
        else { return unknownBundleIdentifier }
        return identifier
    }

    /// Cotypist uses "-" for fields with no site; treat that like no domain at all.
    private static func normalizedDomain(_ domain: String?) -> String? {
        guard let domain = domain?.trimmingCharacters(in: .whitespaces), !domain.isEmpty, domain != "-" else {
            return nil
        }
        return domain
    }

    /// The export writes SQLite-style timestamps ("2026-06-05 16:23:53.028") in UTC.
    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        for format in ["yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}
