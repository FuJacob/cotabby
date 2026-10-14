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
/// Cursor: the newest modification time read. Files changed since are read whole and replace what
/// memory held for them (`MemoryReadPage.completeConversations`, so a shortened file loses its old
/// tail); pages end between files. `liveConversationIDs` lists every file still there, so the sync
/// removes deleted files from memory.
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
        let after = Double(cursor ?? "") ?? 0
        let files = documents().filter { $0.modified > after }.sorted { $0.modified < $1.modified }
        var records: [MemoryIngestRecord] = []
        var complete = Set<String>()
        var newest = after
        var index = 0
        while index < files.count {
            let file = files[index]
            // Stop between files of different times once the page is full, so a resumed sync
            // never skips a file.
            if records.count >= limit, file.modified > newest { break }
            newest = file.modified
            index += 1
            guard let text = DocumentTextExtractor.text(of: file.url) else { continue }
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
        guard newest > after else { return MemoryReadPage(records: [], nextCursor: nil, hasMore: false) }
        return MemoryReadPage(records: records, nextCursor: String(newest), hasMore: index < files.count,
                              completeConversations: complete)
    }

    func liveConversationIDs() -> Set<String>? {
        // A drive that cannot be listed right now must not read as "every file was deleted".
        guard readiness() == .ready else { return nil }
        return Set(documents().map(\.id))
    }

    /// A document file found under a drive: where it is, its stable id, and its modification time.
    struct Document {
        let url: URL
        let id: String
        let modified: Double
    }

    /// Every supported document under the drive's roots, with its id (account folder + path inside
    /// it, stable across syncs) and modification time. Packages (`.pages`, app bundles) are skipped.
    func documents() -> [Document] {
        var found: [Document] = []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        for root in drive.roots() {
            let rootPath = root.resolvingSymlinksInPath().path
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where DocumentTextExtractor.isSupported(url) {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      (values.fileSize ?? .max) <= DocumentTextExtractor.sizeLimit(for: url),
                      let modified = values.contentModificationDate?.timeIntervalSince1970 else { continue }
                let relative = String(url.resolvingSymlinksInPath().path.dropFirst(rootPath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                found.append(Document(url: url, id: root.lastPathComponent + "/" + relative, modified: modified))
            }
        }
        return found
    }
}
