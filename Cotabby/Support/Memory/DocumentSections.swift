import Foundation

/// File overview:
/// Splits a document's text into sections of a few hundred words, each of which becomes one memory
/// record (and is then cut into passages for embedding by the engine).
///
/// Why sections and not whole files: a record is what a search returns and what a prompt or the
/// Playground shows, so it should be about one thing; a 40-page PDF as one record would bury the
/// paragraph that matters. Why not single paragraphs (as the plain-text Documents source does): text
/// pulled from PDFs and slides breaks at every line, and one-line records carry no context.
///
/// Rule: paragraphs (blank-line separated) are packed together up to `maximumCharacters`; a paragraph
/// longer than that is cut at sentence ends, or hard at the limit when it has none. Whitespace is
/// collapsed, near-empty sections are dropped, and a document yields at most `maximumSections`.
/// Pure.
nonisolated enum DocumentSections {
    static let maximumCharacters = 1_500
    static let minimumCharacters = 20
    static let maximumSections = 400

    static func split(_ text: String) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
        var sections: [String] = []
        var current = ""
        func flush() {
            if current.count >= minimumCharacters { sections.append(current) }
            current = ""
        }
        for paragraph in paragraphs.flatMap(pieces) {
            if !current.isEmpty, current.count + 1 + paragraph.count > maximumCharacters { flush() }
            current += current.isEmpty ? paragraph : " " + paragraph
            if sections.count >= maximumSections { break }
        }
        flush()
        return Array(sections.prefix(maximumSections))
    }

    /// A paragraph as pieces of at most `maximumCharacters`, cut after a sentence's end where one
    /// falls in the second half of the limit, else at the last space, else hard.
    static func pieces(_ paragraph: String) -> [String] {
        var rest = Substring(paragraph)
        var pieces: [String] = []
        while rest.count > maximumCharacters {
            let window = rest.prefix(maximumCharacters)
            let half = window.index(window.startIndex, offsetBy: maximumCharacters / 2)
            var cut = window.endIndex
            if let sentence = window[half...].lastIndex(where: { ".!?".contains($0) }) {
                cut = window.index(after: sentence)
            } else if let space = window[half...].lastIndex(of: " ") {
                cut = space
            }
            pieces.append(rest[..<cut].trimmingCharacters(in: .whitespaces))
            rest = rest[cut...].drop(while: { $0 == " " })
        }
        if !rest.isEmpty { pieces.append(String(rest)) }
        return pieces
    }
}
