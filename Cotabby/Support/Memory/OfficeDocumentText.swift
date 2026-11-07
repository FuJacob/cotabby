import Foundation

/// File overview:
/// The text of Word, PowerPoint and Excel files (Office Open XML: `.docx`, `.pptx`, `.xlsx`), for
/// conversation memory's document sources.
///
/// Each format is a ZIP of XML parts (`ZipArchiveReader`), and its text sits in a few element kinds:
/// - Word: `word/document.xml`, runs of `w:t` inside paragraphs `w:p`.
/// - PowerPoint: `ppt/slides/slideN.xml` in slide order, runs of `a:t` inside paragraphs `a:p`;
///   speaker notes (`ppt/notesSlides`) follow their slides' text.
/// - Excel: the shared strings table (`xl/sharedStrings.xml`, items `si` holding `t`), which holds
///   every text cell of the workbook once. Numbers are left out; they carry little meaning alone.
///
/// One `XMLParser` pass per part collects the runs and starts a new line at each paragraph or item,
/// so a slide's bullets and a document's paragraphs stay apart. One budget covers the whole file:
/// the characters and line breaks kept across all its parts (`maximumCharacters`) and the bytes its
/// parts expand to (`maximumExpandedBytes`). A crafted deck of thousands of large slides stops at the
/// budget instead of being expanded whole. Pure: bytes in, text out.
nonisolated enum OfficeDocumentText {
    static let maximumCharacters = 400_000
    static let maximumExpandedBytes = 64 * 1024 * 1024

    enum Kind: String, CaseIterable, Sendable {
        case word = "docx"
        case powerPoint = "pptx"
        case excel = "xlsx"
    }

    /// One XML part of the package to read: its path, the element holding text runs, and the
    /// elements that end a line.
    private struct Part {
        let name: String
        let text: String
        let breaks: Set<String>
    }

    static func text(of data: Data, kind: Kind) throws -> String {
        let archive = try ZipArchiveReader(data: data)
        let parts: [Part]
        switch kind {
        case .word:
            parts = [Part(name: "word/document.xml", text: "w:t", breaks: ["w:p", "w:br", "w:tab"])]
        case .powerPoint:
            parts = (ordered(archive.names, folder: "ppt/slides/slide") + ordered(archive.names, folder: "ppt/notesSlides/notesSlide"))
                .map { Part(name: $0, text: "a:t", breaks: ["a:p", "a:br"]) }
        case .excel:
            parts = [Part(name: "xl/sharedStrings.xml", text: "t", breaks: ["si"])]
        }
        // One lookup table: a deck can list thousands of parts, and a search per part would be quadratic.
        let entries = Dictionary(archive.entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var texts: [String] = []
        var remaining = maximumCharacters
        var expanded = 0
        for part in parts where remaining > 0 {
            guard let entry = entries[part.name] else { continue }
            expanded += entry.uncompressedSize
            guard expanded <= maximumExpandedBytes else { break }
            let text = runs(in: try archive.contents(of: entry), text: part.text, breaks: part.breaks, limit: remaining)
            remaining -= text.count + 2
            if !text.isEmpty { texts.append(text) }
        }
        let text = texts.joined(separator: "\n\n")
        return text.count > maximumCharacters ? String(text.prefix(maximumCharacters)) : text
    }

    /// `folder` + number + ".xml" entries in numeric order ("slide2" before "slide10").
    static func ordered(_ names: [String], folder: String) -> [String] {
        names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix(folder), name.hasSuffix(".xml"),
                  let number = Int(name.dropFirst(folder.count).dropLast(4)) else { return nil }
            return (number, name)
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// The text of every `text` element, with a line break after each `breaks` element.
    static func runs(in xml: Data, text: String, breaks: Set<String>, limit: Int = maximumCharacters) -> String {
        let collector = RunCollector(textElement: text, breakElements: breaks, limit: limit)
        let parser = XMLParser(data: xml)
        parser.shouldResolveExternalEntities = false  // Never fetch anything a document points at.
        parser.delegate = collector
        parser.parse()
        return collector.lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private final class RunCollector: NSObject, XMLParserDelegate {
        let textElement: String
        let breakElements: Set<String>
        private(set) var lines: [String] = [""]
        private var depth = 0
        /// Characters and line breaks kept so far; parsing stops at `limit`.
        private var used = 0
        let limit: Int

        init(textElement: String, breakElements: Set<String>, limit: Int) {
            self.textElement = textElement
            self.breakElements = breakElements
            self.limit = limit
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            if elementName == textElement { depth += 1 }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == textElement { depth = max(0, depth - 1) }
            // An empty line is not started twice: a run of breaks with no text costs nothing to keep.
            if breakElements.contains(elementName), lines.last?.isEmpty == false {
                lines.append("")
                used += 1
                if used > limit { parser.abortParsing() }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard depth > 0 else { return }
            lines[lines.count - 1] += string
            used += string.count
            if used > limit { parser.abortParsing() }
        }
    }
}
