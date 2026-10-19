import Foundation

/// File overview:
/// A folder of notes and documents as a memory source: every paragraph of every text or Markdown
/// file becomes a record, and its file is its conversation.
///
/// Useful as reference facts (pricing, product details, how-tos); the Playground searches them.
/// Files over 2 MB are skipped (exports and logs, not notes).
///
/// Cursor: the newest modification time already read. Files changed since are read whole and
/// replace what memory held for them (`MemoryReadPage.completeConversations`: a shortened note
/// loses its old tail); their paragraphs keep stable ids, so unchanged ones are no-ops in the store.
/// Pages end at a file boundary between different modification times, so a resumed sync never
/// skips a file. `liveConversationIDs` lists every note still there, so deleted notes leave memory.
/// Notes are reference material, so retention does not apply to them (`keepsAllDates`).
nonisolated struct DocumentsHistoryReader: MemoryHistoryReading {
    static let id = "documents"
    let sourceID = Self.id
    let folder: String
    /// The listing the last `read` took, which `liveConversationIDs` reuses in the same sync.
    let lastListing = RecentListing<(notes: [Note], isComplete: Bool)>()

    static let textSuffixes: Set<String> = ["txt", "md", "markdown", "text", "org", "rst"]
    static let maximumFileBytes = 2_000_000
    static let minimumParagraphCharacters = 20

    init(folder: String) {
        self.folder = (folder as NSString).expandingTildeInPath
    }

    func readiness() -> MemorySourceReadiness {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .notFound("\(folder) is not a folder.")
        }
        return FileManager.default.isReadableFile(atPath: folder) ? .ready : .failed("Cotabby cannot read \(folder).")
    }

    func read(after cursor: String?, since: Date?, limit: Int) throws -> MemoryReadPage {
        let after = Double(cursor ?? "") ?? 0
        guard let listing = notes() else { throw ReadOnlySQLiteDatabase.DatabaseError.missing(folder) }
        lastListing.store(listing)
        let files = listing.notes.filter { $0.changed > after }.sorted { $0.changed < $1.changed }

        var records: [MemoryIngestRecord] = []
        var complete = Set<String>()
        var newest = after
        var index = 0
        while index < files.count {
            let file = files[index]
            // Stop between files of different times once the page is full.
            if records.count >= limit, file.changed > newest { break }
            newest = file.changed
            index += 1
            guard let text = try? String(contentsOf: file.url, encoding: .utf8) else { continue }
            let stem = file.url.deletingPathExtension().lastPathComponent
            for (number, paragraph) in Self.paragraphs(text).enumerated() {
                records.append(MemoryIngestRecord(
                    sourceMessageID: "\(file.id)#\(number)", conversationID: file.id, conversationTitle: stem,
                    sender: stem, isFromMe: true, timestamp: Date(timeIntervalSince1970: file.modified),
                    text: paragraph, participants: [], subject: nil
                ))
            }
            // Read whole: paragraphs memory held past the note's new end go.
            complete.insert(file.id)
        }
        guard newest > after else { return MemoryReadPage(records: [], nextCursor: nil, hasMore: false) }
        return MemoryReadPage(records: records, nextCursor: String(newest), hasMore: index < files.count,
                              completeConversations: complete)
    }

    func liveConversationIDs() -> Set<String>? {
        // Only a listing that read every folder may say a note is gone.
        guard let listing = lastListing.take() ?? notes(), listing.isComplete else { return nil }
        return Set(listing.notes.map(\.id))
    }

    /// A note found in the folder: where it is, its id (its path inside the folder) and its
    /// modification time.
    struct Note {
        let url: URL
        let id: String
        let modified: Double
        /// When it last changed or arrived (`DocumentArrival`): what the cursor follows.
        let changed: Double
    }

    /// Every note in the folder, and whether every subfolder could be read (a folder macOS refused
    /// is not the same as one without notes). Nil when the folder itself cannot be listed.
    func notes() -> (notes: [Note], isComplete: Bool)? {
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        guard (try? FileManager.default.contentsOfDirectory(atPath: folder)) != nil else { return nil }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .attributeModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let failures = EnumerationFailures()
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: failures.record
        ) else { return nil }
        // Both sides resolved, since the enumerator reports /private/var for a /var path.
        let rootPath = root.resolvingSymlinksInPath().path
        var notes: [Note] = []
        for case let url as URL in enumerator where Self.textSuffixes.contains(url.pathExtension.lowercased()) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, (values?.fileSize ?? .max) <= Self.maximumFileBytes,
                  let modified = values?.contentModificationDate?.timeIntervalSince1970 else { continue }
            let relative = String(url.resolvingSymlinksInPath().path.dropFirst(rootPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            notes.append(Note(url: url, id: relative, modified: modified,
                              changed: DocumentArrival.changed(modified: modified, values: values)))
        }
        return (notes, !failures.occurred)
    }

    static func paragraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { $0.count >= minimumParagraphCharacters }
    }
}

/// Records whether a directory enumeration hit an error (an unreadable subfolder), which the
/// enumerator otherwise skips silently. Used through its `record` error handler.
/// A folder listing kept briefly: a sync lists a folder to read what changed, then asks which files
/// still exist (`liveConversationIDs`), and a second walk of a large drive cost seconds. Taken once,
/// and only within `maximumAge`, so a later call lists the folder afresh.
nonisolated final class RecentListing<Listing>: @unchecked Sendable {
    static var maximumAge: TimeInterval { 60 }
    private let lock = NSLock()
    private var kept: (listing: Listing, at: Date)?

    func store(_ listing: Listing) {
        lock.lock()
        defer { lock.unlock() }
        kept = (listing, Date())
    }

    func take() -> Listing? {
        lock.lock()
        defer { lock.unlock() }
        defer { kept = nil }
        guard let kept, Date().timeIntervalSince(kept.at) <= Self.maximumAge else { return nil }
        return kept.listing
    }
}

nonisolated final class EnumerationFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false

    var occurred: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }

    /// The enumerator's error handler: notes the failure and continues with the rest.
    func record(_ url: URL, _ error: Error) -> Bool {
        lock.lock()
        failed = true
        lock.unlock()
        return true
    }
}

/// When a document file last changed or arrived where it is, for the readers' cursors.
///
/// A file can turn up with an old modification date: copied or moved in with its date kept,
/// renamed (a new id for the cloud reader), or downloaded by a sync client that sets the server's
/// date. Filtering by modification date alone would leave it unread behind the cursor. The file's
/// status-change time (`attributeModificationDate`, ctime) moves whenever the file is created,
/// moved or renamed (and on permission or extended-attribute changes, which only cost a re-read
/// that changes nothing), so the later of the two is the cursor's key. The date Finder shows as
/// "added" is not used: it does not move on a rename in place.
nonisolated enum DocumentArrival {
    static func changed(modified: Double, values: URLResourceValues?) -> Double {
        max(modified, values?.attributeModificationDate?.timeIntervalSince1970 ?? 0)
    }
}
