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
/// not leave gigabytes of downloads behind. A file that cannot be fetched (offline) yields nil and is
/// read on its next change. Every format has a size cap, since shared drives hold exports and dumps.
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

    /// The file's text, nil when it has none or cannot be read.
    static func text(of url: URL) -> String? {
        let wasOnlineOnly = isOnlineOnly(url)
        defer {
            // Leave the drive as it was: a file downloaded only to be read goes back to the cloud.
            if wasOnlineOnly { try? FileManager.default.evictUbiquitousItem(at: url) }
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
            guard let kind = OfficeDocumentText.Kind(rawValue: suffix),
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            text = try? OfficeDocumentText.text(of: data, kind: kind)
        case _ where richSuffixes.contains(suffix):
            let type: NSAttributedString.DocumentType = suffix == "rtf" ? .rtf : (suffix == "doc" ? .docFormat : .openDocument)
            text = (try? NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil))?.string
        default:
            text = nil
        }
        guard let text, !text.isEmpty else { return nil }
        return text.count > maximumCharacters ? String(text.prefix(maximumCharacters)) : text
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

    /// Whether the file's content is not on this Mac yet (a cloud placeholder). APFS marks such files
    /// "dataless" (`SF_DATALESS` in the BSD flags), for File Provider drives and iCloud Drive alike.
    static func isOnlineOnly(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & UInt32(SF_DATALESS) != 0
    }
}
