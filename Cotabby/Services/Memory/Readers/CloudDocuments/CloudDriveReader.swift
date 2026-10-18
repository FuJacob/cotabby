import CryptoKit
import Foundation
import Logging

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
/// pages end between files. Files that could not be read are tried again on the next sync rather
/// than left behind the cursor; files read with no text in them (a scanned PDF) are not, until they
/// change. `liveConversationIDs` lists every file still there, so the sync removes
/// deleted files from memory, but only from a listing that read every account and folder.
///
/// A file the reader has not seen before arrives at the later of its modification and status-change
/// times (`DocumentArrival`), so a file moved or renamed in with an old date still arrives. A file it
/// has seen changes only when it is modified: its status-change time also moves whenever its
/// content is downloaded or given back (by this reader, the user, or the drive freeing space) and
/// when the drive updates its own records of it, which on a real Google Drive was nearly every file
/// within a day; read on that, unchanged files were downloaded again sync after sync. The cursor
/// keeps the files of the last complete listing (`Cursor.seen`, 8 bytes of each id's SHA-256).
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
    /// When a file last changed or arrived (`DocumentArrival`). A seam for tests: File Provider
    /// placeholders cannot be made on disk.
    var arrival: @Sendable (URL, _ modified: Double, URLResourceValues?) -> Double = { _, modified, values in
        DocumentArrival.changed(modified: modified, values: values)
    }
    /// The listing the last `read` took, which `liveConversationIDs` reuses in the same sync.
    let lastListing = RecentListing<(documents: [Document], isComplete: Bool)>()

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
        let listing = documentListing()
        lastListing.store(listing)
        let found = listing.documents
        let present = Set(found.map(\.id))
        // Files that failed in an earlier sync are tried again (first: they are older than the
        // cursor); ones that failed in this sync wait for the next, so a page never retries them.
        var retry = state.retry.intersection(present)
        var failed = state.failed.intersection(present)
        let listed = Set(present.map(Cursor.seenKey))
        // A cursor from before `seen` existed: what is listed now counts as seen, so the first sync
        // after the update does not read the whole drive again.
        let seen = state.seen ?? listed
        // A file seen before: its modification time alone (see above).
        let files = found.map { file in
            seen.contains(Cursor.seenKey(file.id)) ? file.keyedOnModification : file
        }.filter { $0.changed > state.after || retry.contains($0.id) }
            .sorted { $0.changed < $1.changed }
        var records: [MemoryIngestRecord] = []
        var complete = Set<String>()
        var newest = state.after
        var index = 0
        var withoutText = 0
        var unreadableReasons: [String: Int] = [:]
        while index < files.count {
            let file = files[index]
            // Stop between files of different times once the page is full, so a resumed sync
            // never skips a file.
            if records.count >= limit, file.changed > newest { break }
            newest = max(newest, file.changed)
            index += 1
            retry.remove(file.id)
            let text: String
            switch DocumentTextExtractor.extract(file.url) {
            case let .unreadable(reason):
                failed.insert(file.id)
                unreadableReasons[reason, default: 0] += 1
                continue
            case .noText:
                // Read, with nothing in it (a scanned PDF): done until it changes. What memory held
                // for an earlier version goes.
                failed.remove(file.id)
                complete.insert(file.id)
                withoutText += 1
                continue
            case let .text(extracted):
                text = extracted
            }
            failed.remove(file.id)
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
        guard index > 0 else {
            // Nothing to read: the sync ends here. It hands earlier pages' failures to the next
            // sync, and remembers the files listed: the next sync must know which files are new.
            let next = Cursor(after: state.after, retry: retry.union(failed), failed: [], seen: listed)
            let unchanged = state.seen == listed && failed.isEmpty
            return MemoryReadPage(records: [], nextCursor: unchanged ? nil : next.encoded, hasMore: false)
        }
        let hasMore = index < files.count
        CotabbyLogger.app.info("Cloud drive read", metadata: [
            "source": .string(drive.id),
            "listed": .stringConvertible(found.count),
            "read": .stringConvertible(index),
            "without_text": .stringConvertible(withoutText),
            "unreadable": .stringConvertible(failed.count),
            "unreadable_errors": .string(unreadableReasons.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }
                .joined(separator: ", ")),
            "retried": .stringConvertible(state.retry.intersection(present).count),
            "more": .stringConvertible(hasMore)
        ])
        // The last page of a sync hands this sync's failures to the next one, and its listing.
        let next = hasMore ? Cursor(after: newest, retry: retry, failed: failed, seen: seen)
            : Cursor(after: newest, retry: retry.union(failed), failed: [], seen: listed)
        return MemoryReadPage(records: records, nextCursor: next.encoded, hasMore: hasMore,
                              completeConversations: complete)
    }

    func liveConversationIDs() -> Set<String>? {
        // A drive, account or folder that cannot be listed right now must not read as "every file
        // in it was deleted".
        let listing = lastListing.take() ?? documentListing()
        guard listing.isComplete else { return nil }
        return Set(listing.documents.map(\.id))
    }

    /// Where a sync stands: the newest time read, the files to try again, and the files seen.
    /// Encoded as the time alone while nothing is pending (the form older versions stored), else as
    /// JSON.
    struct Cursor: Codable, Equatable {
        var after: Double
        /// Failed in an earlier sync: read on the next one.
        var retry: Set<String> = []
        /// Failed in the sync under way: moved to `retry` when it ends.
        var failed: Set<String> = []
        /// The files of the last complete listing (`seenKey`); nil in a cursor written before it
        /// existed. Kept as one base64 string of sorted keys, so thousands of files stay small.
        var seen: Set<UInt64>?

        init(after: Double, retry: Set<String> = [], failed: Set<String> = [], seen: Set<UInt64>? = nil) {
            self.after = after
            self.retry = retry
            self.failed = failed
            self.seen = seen
        }

        /// Missing keys (cursors written before a field existed) read as empty; `evicted`, from
        /// before `seen`, is ignored.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CloudDriveCursorKey.self)
            after = try container.decode(Double.self, forKey: .after)
            retry = try container.decodeIfPresent(Set<String>.self, forKey: .retry) ?? []
            failed = try container.decodeIfPresent(Set<String>.self, forKey: .failed) ?? []
            seen = try container.decodeIfPresent(String.self, forKey: .seen).flatMap(Self.decodeKeys)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CloudDriveCursorKey.self)
            try container.encode(after, forKey: .after)
            try container.encode(retry, forKey: .retry)
            try container.encode(failed, forKey: .failed)
            try container.encodeIfPresent(seen.map(Self.encodeKeys), forKey: .seen)
        }

        /// A file id as `seen` keeps it: the first 8 bytes of its SHA-256.
        static func seenKey(_ id: String) -> UInt64 {
            SHA256.hash(data: Data(id.utf8)).prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
        }

        static func encodeKeys(_ keys: Set<UInt64>) -> String {
            var data = Data(capacity: keys.count * 8)
            for key in keys.sorted() { withUnsafeBytes(of: key.bigEndian) { data.append(contentsOf: $0) } }
            return data.base64EncodedString()
        }

        static func decodeKeys(_ text: String) -> Set<UInt64>? {
            guard let data = Data(base64Encoded: text), data.count % 8 == 0 else { return nil }
            return Set(stride(from: 0, to: data.count, by: 8).map { offset in
                data[(data.startIndex + offset)..<(data.startIndex + offset + 8)].reduce(0) { $0 << 8 | UInt64($1) }
            })
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
            if retry.isEmpty, failed.isEmpty, seen == nil { return String(after) }
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

        /// The same file with only its modification time as its time for the cursor.
        var keyedOnModification: Document {
            Document(url: url, id: id, modified: modified, changed: modified)
        }
    }

    /// Every supported document under the drive's roots, with its id (account folder + path inside
    /// it, stable across syncs) and modification time, and whether every root and every folder under them could be read: an
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
                                      changed: arrival(url, modified, values)))
            }
        }
        return (found, isComplete)
    }
}

/// The fields of `CloudDriveReader.Cursor`'s JSON form.
private nonisolated enum CloudDriveCursorKey: String, CodingKey {
    case after, retry, failed, seen
}
