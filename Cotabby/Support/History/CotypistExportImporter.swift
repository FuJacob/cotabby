import Foundation

/// Converts a Cotypist typing-history export into Cotabby history records.
///
/// Cotypist keeps its history in an encrypted database with no export button; the user's decrypted
/// copy is a JSON array of `user_inputs` rows (`textUpToCursor`, `textAfterCursor`,
/// `appBundleIdentifier`, `domain`, `createdAt`, ...). This type maps that shape and does no
/// Keychain access; its only file access is `readExport(at:)`, which bounds the file before it is
/// read, so the mapping itself stays pure and testable.
///
/// Cotypist stores a new row each time it snapshots the same field, so one email can appear dozens
/// of times as it grows. Only the longest (most complete) version of each piece of writing is kept;
/// otherwise retrieval would return near-copies and phrase counts would be inflated by repetition.
/// Rows that share an app and an opening are candidates for being the same writing, but a shorter
/// one is only dropped when nearly all of its words appear in a longer one: two messages that open
/// the same way ("Thanks for reaching out! I'd be happy to…") are different writing and both stay.
nonisolated enum CotypistExportImporter {
    enum ImportError: Error, Equatable, LocalizedError {
        case unrecognizedFormat
        case fileTooLarge
        case tooManyRows

        var errorDescription: String? {
            switch self {
            case .unrecognizedFormat:
                return "This file isn't a Cotypist user_inputs export (a JSON list of typing-history rows)."
            case .fileTooLarge:
                return "This file is larger than \(CotypistExportImporter.maximumExportBytes / 1_048_576) MB, "
                    + "too large to be a Cotypist user_inputs export."
            case .tooManyRows:
                return "This export has more than \(CotypistExportImporter.maximumRows.formatted()) rows, "
                    + "more than Cotabby imports at once."
            }
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

    private static let groupingPrefixLength = 40
    /// Share of a shorter text's words that must appear in a longer text of the same group for the
    /// shorter one to count as an earlier snapshot of it. Edits between snapshots change a few
    /// words; a different message that only shares the opening keeps most of its words to itself.
    private static let snapshotWordShare = 0.8

    /// Largest file accepted. The whole export is decoded in memory, so without a bound a huge file
    /// (or the wrong file picked by mistake) exhausts memory before the format check can reject it.
    /// Real exports, even with Cotypist's many snapshots per field, are far below this.
    static let maximumExportBytes = 50 * 1_048_576
    /// Most rows imported at once. Every row is scrubbed (several regular expressions) and grouped,
    /// so this bounds the import's work; history keeps only `TypingHistoryStore.maximumRecords`.
    static let maximumRows = 250_000

    /// Reads the export at `url`, refusing anything that is not a regular file of at most
    /// `maximumBytes` before reading any of it. The length is checked again after the read in case
    /// the file grew in between.
    static func readExport(
        at url: URL,
        maximumBytes: Int = CotypistExportImporter.maximumExportBytes
    ) throws -> Data {
        let fileURL = url.resolvingSymlinksInPath()
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw ImportError.unrecognizedFormat
        }
        guard size <= maximumBytes else { throw ImportError.fileTooLarge }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard data.count <= maximumBytes else { throw ImportError.fileTooLarge }
        return data
    }

    static func records(
        fromExport data: Data,
        rowLimit: Int = CotypistExportImporter.maximumRows
    ) throws -> [TypingHistoryRecord] {
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else {
            throw ImportError.unrecognizedFormat
        }
        guard rows.count <= rowLimit else { throw ImportError.tooManyRows }
        guard rows.isEmpty || rows.contains(where: { $0.textUpToCursor != nil }) else {
            throw ImportError.unrecognizedFormat
        }

        // Building a DateFormatter is expensive and an export has thousands of rows, so the parsers
        // are made once per import rather than once per timestamp.
        let dateFormatters = makeDateFormatters()
        var groups: [String: [TypingHistoryRecord]] = [:]
        for row in rows {
            let (text, typedLength) = TypingHistoryScrubber.scrub(
                before: row.textUpToCursor ?? "", after: row.textAfterCursor ?? ""
            )
            guard TypingHistoryRecord.isWorthKeeping(text) else { continue }
            let bundleIdentifier = normalizedBundleIdentifier(row.appBundleIdentifier)
            let createdAt = parseDate(row.createdAt, using: dateFormatters) ?? Date(timeIntervalSince1970: 0)
            let record = TypingHistoryRecord(
                id: UUID(),
                bundleIdentifier: bundleIdentifier,
                domain: normalizedDomain(row.domain),
                createdAt: createdAt,
                updatedAt: parseDate(row.updatedAt, using: dateFormatters) ?? createdAt,
                text: text,
                source: .imported,
                typedLength: typedLength
            )
            let key = bundleIdentifier + "\u{1F}" + String(text.prefix(groupingPrefixLength)).lowercased()
            groups[key, default: []].append(record)
        }
        let latestVersions = groups.values.flatMap(latestVersions(in:))
        return droppingEarlierSnapshots(latestVersions).sorted { $0.createdAt < $1.createdAt }
    }

    /// Within one group (same app, same opening), keeps the most complete version of each piece of
    /// writing. Longest first, a text is dropped as an earlier snapshot when nearly all of its words
    /// appear in a longer text already kept; otherwise it is a different message and stays.
    ///
    /// Comparing each text with every kept text was quadratic in a group of thousands of distinct
    /// messages (one support macro, say). The share is now computed only for the kept texts that
    /// could reach it (`snapshotCandidates`); the rule and its arithmetic are unchanged.
    private static func latestVersions(in group: [TypingHistoryRecord]) -> [TypingHistoryRecord] {
        guard group.count > 1 else { return group }
        var kept: [(record: TypingHistoryRecord, words: Set<String>)] = []
        var keptTextsByWord: [String: [Int]] = [:]
        for record in group.sorted(by: { $0.text.count > $1.text.count }) {
            let words = Set(TypingHistoryIndex.terms(in: record.text))
            let isEarlierSnapshot: Bool
            if kept.isEmpty {
                isEarlierSnapshot = false
            } else if words.isEmpty {
                // A text with no informative words beyond the shared opening says nothing new.
                isEarlierSnapshot = true
            } else {
                isEarlierSnapshot = snapshotCandidates(for: words, in: keptTextsByWord).contains { keptIndex in
                    Double(words.intersection(kept[keptIndex].words).count) / Double(words.count) >= snapshotWordShare
                }
            }
            guard !isEarlierSnapshot else { continue }
            for word in words {
                keptTextsByWord[word, default: []].append(kept.count)
            }
            kept.append((record, words))
        }
        return kept.map(\.record)
    }

    /// The kept texts (indices) that could hold `snapshotWordShare` of `words`. Such a text lacks
    /// at most `words.count - required` of them, so it contains at least one of any
    /// `words.count - required + 1`; looking only at the texts holding the rarest that many skips
    /// texts that merely share the group's opening words. Exact: no qualifying text is left out.
    private static func snapshotCandidates(for words: Set<String>, in keptTextsByWord: [String: [Int]]) -> Set<Int> {
        let required = (0...words.count).first { Double($0) / Double(words.count) >= snapshotWordShare } ?? words.count
        let probes = words.count - required + 1
        let rarest = words.map { keptTextsByWord[$0] ?? [] }.sorted { $0.count < $1.count }.prefix(probes)
        return Set(rarest.joined())
    }

    /// A field's early snapshots can be shorter than the grouping prefix ("Hi Arnaud, the POC is
    /// read"), so they land in their own group. Within each app, drop any text that is the start of
    /// a longer text: it is the same writing, caught before it was finished.
    ///
    /// Sorted character by character, every text that starts with a given text comes right after
    /// it, so one comparison with the next text answers what comparing against every kept text did
    /// (quadratic on a large export). It is the same rule: a text that is the start of a dropped
    /// text is also the start of the longer one that text was dropped for. Exact copies never get
    /// here, because `latestVersions` already keeps one of them.
    private static func droppingEarlierSnapshots(_ records: [TypingHistoryRecord]) -> [TypingHistoryRecord] {
        var kept: [TypingHistoryRecord] = []
        for (_, appRecords) in Dictionary(grouping: records, by: \.bundleIdentifier) {
            let ordered = appRecords.sorted { $0.text.lexicographicallyPrecedes($1.text) }
            for (index, record) in ordered.enumerated() {
                let next = ordered.index(after: index)
                if next < ordered.endIndex, ordered[next].text.hasPrefix(record.text) { continue }
                kept.append(record)
            }
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

    /// The export writes SQLite-style timestamps ("2026-06-05 16:23:53.028") in UTC; ISO 8601 forms
    /// are accepted too. Tried in this order.
    private static func makeDateFormatters() -> [DateFormatter] {
        ["yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = format
            return formatter
        }
    }

    private static func parseDate(_ string: String?, using formatters: [DateFormatter]) -> Date? {
        guard let string else { return nil }
        return formatters.lazy.compactMap { $0.date(from: string) }.first
    }
}
