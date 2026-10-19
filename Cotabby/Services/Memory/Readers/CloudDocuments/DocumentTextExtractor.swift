import AppKit
import Foundation
import PDFKit

/// File overview:
/// Gets the text out of a document file for conversation memory: plain text and Markdown, PDF,
/// Word / PowerPoint / Excel, RTF, Word 97 and OpenDocument text.
///
/// Which tool for which format:
/// - Text and Markdown: read as UTF-8, else in the encoding Foundation detects.
/// - PDF: PDFKit, page by page up to `maximumPDFPages` (a scanned PDF has no text and yields none).
/// - `.docx`, `.pptx`, `.xlsx`: `OfficeDocumentText`, reading the XML inside the ZIP.
/// - `.rtf`, `.doc`, `.odt`: AppKit's text system (`NSAttributedString` document import), which reads
///   these off the main thread; HTML import is never used (it needs the main thread and WebKit).
///
/// Online-only files: Google Drive, OneDrive and iCloud Drive keep many files as placeholders whose
/// content is still in the cloud ("dataless" on disk). Reading one makes the sync client download
/// it; afterwards the local copy is evicted again (`evictUbiquitousItem`), so indexing a drive does
/// not leave gigabytes of downloads behind. Every format has a size cap, since shared drives hold
/// exports and dumps.
///
/// What reading gave (`Extraction`): text; no text in a file that was read (a scanned or locked PDF,
/// an empty file), which stays so until the file changes; or no access to the file's bytes at all
/// (offline, permissions), which may pass. Readers try the last again on their next sync, never the
/// second: a drive with many scanned PDFs would otherwise download and parse each on every sync.
nonisolated enum DocumentTextExtractor {
    static let plainSuffixes: Set<String> = ["txt", "md", "markdown", "text", "org", "rst"]
    static let richSuffixes: Set<String> = ["rtf", "doc", "odt"]
    static let officeSuffixes = Set(OfficeDocumentText.Kind.allCases.map(\.rawValue))
    static let supportedSuffixes = plainSuffixes.union(richSuffixes).union(officeSuffixes).union(["pdf"])

    static let maximumPlainBytes = 5_000_000
    static let maximumDocumentBytes = 60_000_000
    static let maximumPDFPages = 300
    static let maximumCharacters = OfficeDocumentText.maximumCharacters

    static func isSupported(_ url: URL) -> Bool {
        supportedSuffixes.contains(url.pathExtension.lowercased())
    }

    /// The largest file of this kind memory reads.
    static func sizeLimit(for url: URL) -> Int {
        plainSuffixes.contains(url.pathExtension.lowercased()) ? maximumPlainBytes : maximumDocumentBytes
    }

    enum Extraction: Equatable {
        case text(String)
        /// Read, but there is no text in it: not worth reading again until the file changes.
        case noText
        /// The file's bytes could not be read (an online-only file while offline, no permission),
        /// with the error's domain and code for the log.
        case unreadable(String)
    }

    static func extract(_ url: URL) -> Extraction {
        let wasOnlineOnly = isOnlineOnly(url)
        defer {
            // Leave the drive as it was: a file downloaded only to be read goes back to the cloud.
            if wasOnlineOnly { giveBack(url) }
        }
        // Reading the first byte fetches an online-only file; failing here is no access, which
        // may pass, unlike a file that opens but holds no text.
        // (An empty file reads as nil, not as an error.)
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            _ = try handle.read(upToCount: 1)
        } catch {
            let error = error as NSError
            return .unreadable("\(error.domain) \(error.code)")
        }
        let suffix = url.pathExtension.lowercased()
        let text: String?
        switch suffix {
        case _ where plainSuffixes.contains(suffix):
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? {
                var encoding = String.Encoding.utf8
                return try? String(contentsOf: url, usedEncoding: &encoding)
            }()
        case "pdf":
            text = pdfText(url)
        case _ where officeSuffixes.contains(suffix):
            guard let kind = OfficeDocumentText.Kind(rawValue: suffix) else { return .noText }
            let data: Data
            do {
                data = try Data(contentsOf: url, options: .mappedIfSafe)
            } catch {
                let error = error as NSError
                return .unreadable("\(error.domain) \(error.code)")
            }
            text = try? OfficeDocumentText.text(of: data, kind: kind)
        case _ where richSuffixes.contains(suffix):
            let type: NSAttributedString.DocumentType = suffix == "rtf" ? .rtf : (suffix == "doc" ? .docFormat : .openDocument)
            text = (try? NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil))?.string
        default:
            text = nil
        }
        guard let text, !text.isEmpty else { return .noText }
        return .text(text.count > maximumCharacters ? String(text.prefix(maximumCharacters)) : text)
    }

    private static func pdfText(_ url: URL) -> String? {
        guard let document = PDFDocument(url: url), !document.isLocked else { return nil }
        var pages: [String] = []
        var characters = 0
        for index in 0..<min(document.pageCount, maximumPDFPages) {
            guard let page = document.page(at: index)?.string, !page.isEmpty else { continue }
            pages.append(page)
            characters += page.count
            if characters > maximumCharacters { break }
        }
        // Pages are kept apart as paragraphs; lines inside a page are joined by DocumentSections.
        return pages.joined(separator: "\n\n")
    }

    /// Evicts a file downloaded only to be read. Right after the read the drive can still hold the
    /// file ("in use", EBUSY): on a real Google Drive 4 of 138 evictions failed that way and left
    /// the download behind, so a busy file is tried again a few times.
    static func giveBack(_ url: URL, attempts: Int = 4, pause: TimeInterval = 0.5) {
        for attempt in 1...attempts {
            do {
                try FileManager.default.evictUbiquitousItem(at: url)
                return
            } catch {
                guard attempt < attempts, isBusy(error) else { return }
                Thread.sleep(forTimeInterval: pause * Double(attempt))
            }
        }
    }

    static func isBusy(_ error: Error) -> Bool {
        let error = error as NSError
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        return [error, underlying].contains { $0?.domain == NSPOSIXErrorDomain && $0?.code == Int(EBUSY) }
    }

    /// Whether the file's content is not on this Mac yet (a cloud placeholder). APFS marks such files
    /// "dataless" (`SF_DATALESS` in the BSD flags), for File Provider drives and iCloud Drive alike.
    static func isOnlineOnly(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & UInt32(SF_DATALESS) != 0
    }
}
