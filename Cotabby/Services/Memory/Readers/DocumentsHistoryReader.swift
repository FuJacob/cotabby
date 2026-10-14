import Foundation

/// File overview:
/// A folder of notes and documents as a memory source: every paragraph of every text or Markdown
/// file becomes a record, and its file is its conversation.
///
/// Useful as reference facts (pricing, product details, how-tos); the Playground searches them.
/// Files over 2 MB are skipped (exports and logs, not notes).
///
/// Cursor: the newest modification time already read. Files changed since are read whole; their
/// paragraphs keep stable ids, so unchanged ones are no-ops in the store. Pages end at a file
/// boundary between different modification times, so a resumed sync never skips a file.
nonisolated struct DocumentsHistoryReader: MemoryHistoryReading {
    static let id = "documents"
    let sourceID = Self.id
    let folder: String

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
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw ReadOnlySQLiteDatabase.DatabaseError.missing(folder) }

        var files: [(url: URL, modified: Double)] = []
        for case let url as URL in enumerator where Self.textSuffixes.contains(url.pathExtension.lowercased()) {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, (values?.fileSize ?? .max) <= Self.maximumFileBytes,
                  let modified = values?.contentModificationDate?.timeIntervalSince1970, modified > after else { continue }
            files.append((url, modified))
        }
        files.sort { $0.modified < $1.modified }

        var records: [MemoryIngestRecord] = []
        var newest = after
        var index = 0
        while index < files.count {
            let file = files[index]
            // Stop between files of different times once the page is full.
            if records.count >= limit, file.modified > newest { break }
            newest = file.modified
            index += 1
            guard let text = try? String(contentsOf: file.url, encoding: .utf8) else { continue }
            // Both sides resolved, since the enumerator reports /private/var for a /var path.
            let rootPath = root.resolvingSymlinksInPath().path
            let relative = String(file.url.resolvingSymlinksInPath().path.dropFirst(rootPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let stem = file.url.deletingPathExtension().lastPathComponent
            for (number, paragraph) in Self.paragraphs(text).enumerated() {
                records.append(MemoryIngestRecord(
                    sourceMessageID: "\(relative)#\(number)", conversationID: relative, conversationTitle: stem,
                    sender: stem, isFromMe: true, timestamp: Date(timeIntervalSince1970: file.modified),
                    text: paragraph, participants: [], subject: nil
                ))
            }
        }
        guard newest > after else { return MemoryReadPage(records: [], nextCursor: nil, hasMore: false) }
        return MemoryReadPage(records: records, nextCursor: String(newest), hasMore: index < files.count)
    }

    static func paragraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { $0.count >= minimumParagraphCharacters }
    }
}
