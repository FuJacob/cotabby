import CryptoKit
import Foundation

/// File overview:
/// Reads the documents of a cloud drive synced to this Mac (iCloud Drive, Google Drive, OneDrive)
/// into conversation memory, where the Playground can search them.
///
/// Where the drives are: iCloud Drive in `~/Library/Mobile Documents/com~apple~CloudDocs`; Google
/// Drive and OneDrive through macOS's File Provider in `~/Library/CloudStorage`, one folder per
/// account (`GoogleDrive-<account>`, `OneDrive-<account>`, and one per shared library). Every
/// account's folder is read, as one source per drive. Nothing is fetched from Google or Microsoft
/// directly; online-only files are downloaded by the drive's own app when read
/// (`DocumentTextExtractor`), then given back.
///
/// Mapping: each file is a conversation titled with its name; its text is split into sections
/// (`DocumentSections`), one record each, sender empty (a shared document's author is not known,
/// and it is never the user's own words). Google Docs, Sheets and Slides (`.gdoc`...) are only links
/// on the Mac; their text stays in Google's cloud and is not read.
///
/// Cursor: the newest modification time read, plus the files that could not be read (an
/// online-only file while offline). Files changed since are read whole and replace what memory
/// held for them (`MemoryReadPage.completeConversations`, so a shortened file loses its old tail);
/// pages end between files. Unreadable files are tried again on the next sync rather than left
/// behind the cursor. `liveConversationIDs` lists every file still there, so the sync removes
/// deleted files from memory, but only from a listing that read every account and folder.
///
/// A file's time for the cursor is the later of its modification and status-change times
/// (`DocumentArrival`), so a file moved or renamed in with an old date still arrives. Reading an
/// online-only file downloads it and gives it back (`DocumentTextExtractor`), and giving it back
/// moves its status-change time too; keyed on that, the file would look new on every sync and be
/// downloaded again each time. So the cursor also remembers which files this reader gave back
/// (`Cursor.evicted`, hashed), and while such a file is still online-only only its modification
/// time counts: an edit still brings it back, our own eviction does not. A file moved or renamed in
/// has a new id, so the arrival rule still applies to it.
nonisolated struct CloudDriveReader: MemoryHistoryReading {
    nonisolated struct Drive: Sendable {
        let id: String
        let title: String
        /// The folders holding the drive's files, those that exist on this Mac.
        let roots: @Sendable () -> [URL]
    }

    static let iCloudDrive = Drive(id: "icloud_drive", title: "iCloud Drive") {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? [url] : []
    }
    static let googleDrive = Drive(id: "google_drive", title: "Google Drive") { cloudStorageFolders(prefix: "GoogleDrive-") }
    static let oneDrive = Drive(id: "onedrive", title: "OneDrive") { cloudStorageFolders(prefix: "OneDrive-") }
    static let all: [Drive] = [iCloudDrive, googleDrive, oneDrive]

    /// `~/Library/CloudStorage` folders of one provider. The provider's trash is left out.
    static func cloudStorageFolders(prefix: String, root: String = NSHomeDirectory() + "/Library/CloudStorage") -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return names.filter { $0.hasPrefix(prefix) && !$0.lowercased().contains(".trash") }.sorted()
            .map { URL(fileURLWithPath: root + "/" + $0, isDirectory: true) }
    }

    let drive: Drive
    var sourceID: String { drive.id }
    /// Whether a file's content is only in the cloud right now. A seam for tests: a File Provider
    /// cannot be faked on disk.
    var isOnlineOnly: @Sendable (URL) -> Bool = { DocumentTextExtractor.isOnlineOnly($0) }
    /// When a file last changed or arrived (`DocumentArrival`). A seam for tests, as above.
    var arrival: @Sendable (URL, _ modified: Double, URLResourceValues?) -> Double = { _, modified, values in
        DocumentArrival.changed(modified: modified, values: values)
    }

    init(drive: Drive) {
        self.drive = drive
    }

    func readiness() -> MemorySourceReadiness {
        let roots = drive.roots()
        guard !roots.isEmpty else { return .notFound("\(drive.title) is not set up on this Mac.") }
        // Listing a root is what macOS protects: refused means Full Disk Access is missing.
        for root in roots where (try? FileManager.default.contentsOfDirectory(atPath: root.path)) != nil {
            return .ready
        }
        return .needsFullDiskAccess
    }

    func read(after cursor: String?, since: Date?, limit: Int) throws -> MemoryReadPage {
        let state = Cursor(cursor)
        let found = documents()
        let present = Set(found.map(\.id))
        // Files that failed in an earlier sync are tried again (first: they are older than the
        // cursor); ones that failed in this sync wait for the next, so a page never retries them.
        var retry = state.retry.intersection(present)
        var failed = state.failed.intersection(present)
        var evicted = state.evicted.intersection(Set(present.map(Cursor.evictionKey)))
        // A file this reader gave back, still online-only: its modification time alone (see above).
        let files = found.map { file in
            file.isOnlineOnly && evicted.contains(Cursor.evictionKey(file.id)) ? file.keyedOnModification : file
        }.filter { $0.changed > state.after || retry.contains($0.id) }
            .sorted { $0.changed < $1.changed }
        var records: [MemoryIngestRecord] = []
        var complete = Set<String>()
        var newest = state.after
        var index = 0
        while index < files.count {
            let file = files[index]
            // Stop between files of different times once the page is full, so a resumed sync
            // never skips a file.
            if records.count >= limit, file.changed > newest { break }
            newest = max(newest, file.changed)
            index += 1
            retry.remove(file.id)
            guard let text = DocumentTextExtractor.text(of: file.url) else {
                failed.insert(file.id)
                continue
            }
            failed.remove(file.id)
            // Read while online-only: the extractor downloaded it and gave it back.
            if file.isOnlineOnly { evicted.insert(Cursor.evictionKey(file.id)) }
            let title = file.url.deletingPathExtension().lastPathComponent
            for (number, section) in DocumentSections.split(text).enumerated() {
                records.append(MemoryIngestRecord(
                    sourceMessageID: "\(file.id)#\(number)", conversationID: file.id, conversationTitle: title,
                    sender: "", isFromMe: false, timestamp: Date(timeIntervalSince1970: file.modified),
                    text: section, participants: [], subject: nil
                ))
            }
            complete.insert(file.id)
        }
        guard index > 0 else { return MemoryReadPage(records: [], nextCursor: nil, hasMore: false) }
        let hasMore = index < files.count
        // The last page of a sync hands this sync's failures to the next one.
        let next = hasMore ? Cursor(after: newest, retry: retry, failed: failed, evicted: evicted)
            : Cursor(after: newest, retry: retry.union(failed), failed: [], evicted: evicted)
        return MemoryReadPage(records: records, nextCursor: next.encoded, hasMore: hasMore,
                              completeConversations: complete)
    }

    func liveConversationIDs() -> Set<String>? {
        // A drive, account or folder that cannot be listed right now must not read as "every file
        // in it was deleted".
        let listing = documentListing()
        guard listing.isComplete else { return nil }
        return Set(listing.documents.map(\.id))
    }

    /// Where a sync stands: the newest modification time read, and the files to try again.
    /// Encoded as the time alone while nothing failed (the form older versions stored), else as
    /// JSON.
    struct Cursor: Codable, Equatable {
        var after: Double
        /// Failed in an earlier sync: read on the next one.
        var retry: Set<String> = []
        /// Failed in the sync under way: moved to `retry` when it ends.
        var failed: Set<String> = []
        /// Files this reader read while online-only, and so gave back (`evictionKey` of their ids).
        var evicted: Set<String> = []

        init(after: Double, retry: Set<String> = [], failed: Set<String> = [], evicted: Set<String> = []) {
            self.after = after
            self.retry = retry
            self.failed = failed
            self.evicted = evicted
        }

        /// Missing keys (cursors written before a field existed) read as empty.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            after = try container.decode(Double.self, forKey: .after)
            retry = try container.decodeIfPresent(Set<String>.self, forKey: .retry) ?? []
            failed = try container.decodeIfPresent(Set<String>.self, forKey: .failed) ?? []
            evicted = try container.decodeIfPresent(Set<String>.self, forKey: .evicted) ?? []
        }

        /// A file id as `evicted` keeps it: 16 hex digits of its SHA-256, so a drive with thousands
        /// of online-only files keeps a small cursor.
        static func evictionKey(_ id: String) -> String {
            SHA256.hash(data: Data(id.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        }

        init(_ stored: String?) {
            if let stored, let time = Double(stored) {
                self.init(after: time)
            } else if let data = stored?.data(using: .utf8), let decoded = try? JSONDecoder().decode(Cursor.self, from: data) {
                self = decoded
            } else {
                self.init(after: 0)
            }
        }

        var encoded: String {
            if retry.isEmpty, failed.isEmpty, evicted.isEmpty { return String(after) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return (try? encoder.encode(self)).flatMap { String(bytes: $0, encoding: .utf8) } ?? String(after)
        }
    }

    /// A document file found under a drive: where it is, its stable id, its modification time
    /// (the records' timestamp) and when it last changed or arrived (`changed`, what the cursor
    /// follows).
    struct Document {
        let url: URL
        let id: String
        let modified: Double
        let changed: Double
        /// Only in the cloud when listed (a placeholder the drive downloads when read).
        var isOnlineOnly = false

        /// The same file with only its modification time as its time for the cursor.
        var keyedOnModification: Document {
            Document(url: url, id: id, modified: modified, changed: modified, isOnlineOnly: isOnlineOnly)
        }
    }

    /// Every supported document under the drive's roots, with its id (account folder + path inside
    /// it, stable across syncs) and modification time. Packages (`.pages`, app bundles) are skipped.
    func documents() -> [Document] {
        documentListing().documents
    }

    /// The documents, and whether every root and every folder under them could be read: an
    /// account folder macOS refused, or a subfolder the enumerator could not open, makes the
    /// listing incomplete, and an incomplete listing never removes anything from memory.
    func documentListing() -> (documents: [Document], isComplete: Bool) {
        var found: [Document] = []
        let roots = drive.roots()
        // No account folder at all is a drive not set up (or hidden right now), not an empty one.
        var isComplete = !roots.isEmpty
        let keys: [URLResourceKey] = [.contentModificationDateKey, .attributeModificationDateKey, .fileSizeKey, .isRegularFileKey]
        for root in roots {
            let rootPath = root.resolvingSymlinksInPath().path
            let failures = EnumerationFailures()
            guard (try? FileManager.default.contentsOfDirectory(atPath: root.path)) != nil,
                  let enumerator = FileManager.default.enumerator(
                      at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants],
                      errorHandler: failures.record
                  ) else {
                isComplete = false
                continue
            }
            defer { if failures.occurred { isComplete = false } }
            for case let url as URL in enumerator where DocumentTextExtractor.isSupported(url) {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      (values.fileSize ?? .max) <= DocumentTextExtractor.sizeLimit(for: url),
                      let modified = values.contentModificationDate?.timeIntervalSince1970 else { continue }
                let relative = String(url.resolvingSymlinksInPath().path.dropFirst(rootPath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                found.append(Document(url: url, id: root.lastPathComponent + "/" + relative, modified: modified,
                                      changed: arrival(url, modified, values), isOnlineOnly: isOnlineOnly(url)))
            }
        }
        return (found, isComplete)
    }
}
