import Foundation

/// File overview:
/// Pulls the readable body text out of a raw email (RFC 822 / MIME), for conversation memory.
///
/// Why a hand-written parser: macOS ships no public MIME API, and memory needs only one thing from
/// a message, the text a person wrote. This handles what real mail uses for that: header folding,
/// multipart nesting, `base64` and `quoted-printable` transfer encodings, and charsets by IANA name
/// (UTF-8, ISO-8859-x, Windows-125x including Turkish 1254). `text/plain` is preferred; an
/// HTML-only message is reduced to text. Attachments are skipped. Pure value logic, so every rule
/// is unit-tested without Mail.
nonisolated enum EmailBodyExtractor {
    /// The maximum characters of body kept. Memory only needs the gist of a message, and quoted
    /// history (stripped by the engine) makes long tails mostly repetition.
    static let maximumCharacters = 6000
    /// Email is attacker-controlled input parsed inside Cotabby, so the structure it may describe
    /// is bounded: nesting deeper than this, or more parts than this, is not read (no legitimate
    /// mail comes close), so a crafted message can neither overflow the stack nor stall a sync.
    static let maximumDepth = 8
    static let maximumParts = 64
    /// Messages larger than this (attachments included) are skipped by the Mail reader before
    /// being loaded at all.
    static let maximumMessageBytes = 10 * 1024 * 1024

    /// Mail's `.emlx` files start with the message's byte length on its own line, followed by the
    /// raw message and an XML property list. Returns the body text, or nil when there is none.
    static func bodyFromEmlx(_ data: Data) -> String? {
        guard let newline = data.firstIndex(of: 0x0A),
              let length = Int(String(lossyUTF8: data[data.startIndex..<newline])
                .trimmingCharacters(in: .whitespaces)) else {
            return body(fromMessage: data)
        }
        let start = data.index(after: newline)
        let end = min(data.endIndex, start + length)
        return body(fromMessage: data[start..<end])
    }

    static func body(fromMessage message: Data) -> String? {
        guard message.count <= maximumMessageBytes else { return nil }
        let part = MIMEPart(message)
        var budget = maximumParts
        guard let text = bestText(in: part, depth: 0, budget: &budget) else { return nil }
        let cleaned = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return cleaned.count > maximumCharacters ? String(cleaned.prefix(maximumCharacters)) : cleaned
    }

    // MARK: - Choosing the text part

    private static func bestText(in part: MIMEPart, depth: Int, budget: inout Int) -> String? {
        if part.isAttachment { return nil }
        if part.mediaType.hasPrefix("multipart/") {
            guard depth < maximumDepth else { return nil }
            let children = part.children(limit: budget)
            budget -= children.count
            if part.mediaType == "multipart/alternative" {
                // Alternatives are ordered plainest first; prefer plain text, then HTML.
                if let plain = children.first(where: { $0.mediaType == "text/plain" && !$0.isAttachment }) {
                    return plain.decodedText()
                }
            }
            for child in children where budget >= 0 {
                if let text = bestText(in: child, depth: depth + 1, budget: &budget) { return text }
            }
            return nil
        }
        switch part.mediaType {
        case "text/plain", "": return part.decodedText()
        case "text/html": return part.decodedText().map(htmlToText)
        default: return nil
        }
    }

    // MARK: - HTML

    /// HTML longer than this is cut before conversion: the kept text is a few thousand characters,
    /// and a crafted message must not make conversion cost grow with its size.
    static let maximumHTMLCharacters = 1_000_000

    /// HTML to plain text in one linear pass over the scalars. Not regular expressions: patterns
    /// such as `<style>.*?</style>` or `<[^>]+>` rescan the rest of the input from every unclosed
    /// `<`, so a crafted mail made of them would take quadratic time and stall a sync.
    ///
    /// Block ends (`br`, `p`, `div`, `tr`, `li`, `h1`…`h6`) become line breaks, `style`, `script` and
    /// `head` are dropped with their content, and a `blockquote` opens a "> " quoted line so the
    /// engine's quote stripping removes it like plain-text quoting.
    static func htmlToText(_ html: String) -> String {
        let scalars = Array(html.unicodeScalars.prefix(maximumHTMLCharacters))
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "<" else {
                output.append(scalars[index])
                index += 1
                continue
            }
            // No ">" after an unclosed "<" means no later tag closes either: the rest is text.
            guard let close = scalars[(index + 1)...].firstIndex(of: ">") else {
                output.append(contentsOf: scalars[index...])
                break
            }
            let tag = HTMLTag(scalars[(index + 1)..<close])
            index = close + 1
            if !tag.isClosing, ["style", "script", "head"].contains(tag.name) {
                index = endOfElement(tag.name, in: scalars, from: index) ?? scalars.count
                output.append(" ")
            } else if tag.name == "br" || (tag.isClosing && HTMLTag.blockEnds.contains(tag.name)) {
                output.append("\n")
            } else if tag.name == "blockquote", !tag.isClosing {
                output.append(contentsOf: "\n> ".unicodeScalars)
            }
        }
        return collapseBlankLines(collapseSpaces(decodeEntities(String(output))))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Just past the end tag of `name` (case-insensitive) at or after `start`, or nil when there is
    /// none. One forward scan.
    private static func endOfElement(_ name: String, in scalars: [Unicode.Scalar], from start: Int) -> Int? {
        let name = Array(name.unicodeScalars)
        var index = start
        while index + 1 + name.count < scalars.count {
            if scalars[index] == "<", scalars[index + 1] == "/",
               zip(name, scalars[(index + 2)...]).allSatisfy({ $0 == HTMLTag.lowercased($1) }) {
                return scalars[(index + 2)...].firstIndex(of: ">").map { $0 + 1 }
            }
            index += 1
        }
        return nil
    }

    /// Runs of spaces and tabs become one space.
    private static func collapseSpaces(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        var previousWasSpace = false
        for scalar in text.unicodeScalars {
            let isSpace = scalar == " " || scalar == "\t"
            if !(isSpace && previousWasSpace) { output.append(isSpace ? " " : scalar) }
            previousWasSpace = isSpace
        }
        return String(output)
    }

    /// Two or more blank (or whitespace-only) lines in a row become one blank line.
    private static func collapseBlankLines(_ text: String) -> String {
        var lines: [Substring] = []
        var previousWasBlank = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let isBlank = line.allSatisfy(\.isWhitespace)
            if isBlank, previousWasBlank { continue }
            lines.append(isBlank ? "" : line)
            previousWasBlank = isBlank
        }
        return lines.joined(separator: "\n")
    }

    static func decodeEntities(_ text: String) -> String {
        let named = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        var result = text
        for (entity, value) in named {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        // Numeric entities: &#246; and &#xF6;. The digits are bounded, so a long run of them is
        // tried once, not once per length.
        guard let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]{1,8});") else { return result }
        let source = result as NSString
        var output = ""
        var last = 0
        for match in regex.matches(in: result, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: last, length: match.range.location - last))
            let isHex = source.substring(with: match.range(at: 1)) == "x"
            let digits = source.substring(with: match.range(at: 2))
            if let value = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                output.unicodeScalars.append(scalar)
            }
            last = match.range.location + match.range.length
        }
        output += source.substring(from: last)
        return output
    }
}

/// The name of an HTML tag (between its `<` and `>`), lowercased, and whether it is an end tag.
private nonisolated struct HTMLTag {
    static let blockEnds: Set<String> = ["p", "div", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6"]

    let name: String
    let isClosing: Bool

    init(_ inner: ArraySlice<Unicode.Scalar>) {
        var scalars = inner.drop(while: { $0 == " " })
        isClosing = scalars.first == "/"
        if isClosing { scalars = scalars.dropFirst() }
        let letters = scalars.prefix { (scalar: Unicode.Scalar) -> Bool in
            switch Self.lowercased(scalar) {
            case "a"..."z", "0"..."9": return true
            default: return false
            }
        }
        name = String(String.UnicodeScalarView(letters.prefix(16).map(Self.lowercased)))
    }

    static func lowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        ("A"..."Z").contains(scalar) ? Unicode.Scalar(scalar.value + 32)! : scalar
    }
}

/// One MIME entity: its headers and its raw body bytes.
private nonisolated struct MIMEPart {
    let headers: [String: String]
    let body: Data

    init(_ data: Data) {
        let (headerData, bodyData) = Self.split(data)
        headers = Self.parseHeaders(headerData)
        body = bodyData
    }

    /// Splits at the first blank line (CRLF or LF). Slices, not copies: a nested part would
    /// otherwise copy its bytes once per level.
    private static func split(_ data: Data) -> (Data, Data) {
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == 0x0A {
                if index + 1 < data.endIndex, data[index + 1] == 0x0A {
                    return (data[data.startIndex..<index], data[(index + 2)...])
                }
                if index + 2 < data.endIndex, data[index + 1] == 0x0D, data[index + 2] == 0x0A {
                    return (data[data.startIndex..<index], data[(index + 3)...])
                }
            }
            index += 1
        }
        return (data, Data())
    }

    /// Headers beyond this many bytes are not read (real header blocks are a few kilobytes); a
    /// message with no blank line would otherwise be parsed whole as headers.
    static let maximumHeaderBytes = 64 * 1024
    /// RFC 2046 limits a boundary to 70 characters; a longer one is not searched for.
    static let maximumBoundaryLength = 70

    private static func parseHeaders(_ data: Data) -> [String: String] {
        // Headers are ASCII (RFC 2047 encoded words aside, which memory does not need here).
        // Carriage returns are dropped entirely: with CRLF line endings a header value would
        // otherwise keep a trailing "\r" (not in `.whitespaces`), and "base64\r" or "text/plain\r"
        // would match nothing.
        let text = String(lossyUTF8: data.prefix(maximumHeaderBytes)).replacingOccurrences(of: "\r", with: "")
        var headers: [String: String] = [:]
        var currentName: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t", let name = currentName {
                headers[name, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)  // Folded line.
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            currentName = name
        }
        return headers
    }

    /// `type/subtype`, lowercased; empty when absent (which RFC 2045 says means text/plain).
    var mediaType: String {
        guard let value = headers["content-type"] else { return "" }
        return value.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    }

    func parameter(_ name: String, of header: String) -> String? {
        guard let value = headers[header] else { return nil }
        for piece in value.split(separator: ";").dropFirst() {
            let pair = piece.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == name else { continue }
            return pair[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    var isAttachment: Bool {
        (headers["content-disposition"]?.lowercased().hasPrefix("attachment")) == true
    }

    /// The parts of a multipart body, split on the boundary as raw bytes. Splitting decoded text
    /// instead would mangle a part in a legacy charset (Windows-1254, ISO-8859-9) before its own
    /// charset is applied.
    func children(limit: Int) -> [MIMEPart] {
        guard let boundary = parameter("boundary", of: "content-type"), !boundary.isEmpty,
              boundary.count <= Self.maximumBoundaryLength else { return [] }
        let delimiter = Data(("--" + boundary).utf8)
        var parts: [MIMEPart] = []
        var searchStart = body.startIndex
        var partStart: Data.Index?
        while parts.count < limit, let found = body.range(of: delimiter, in: searchStart..<body.endIndex) {
            if let start = partStart {
                var end = found.lowerBound
                // The line break before a delimiter belongs to the delimiter, not the part.
                if end > start, body[body.index(before: end)] == 0x0A { end = body.index(before: end) }
                if end > start, body[body.index(before: end)] == 0x0D { end = body.index(before: end) }
                parts.append(MIMEPart(body[start..<max(start, end)]))
            }
            var next = found.upperBound
            // "--boundary--" closes the multipart.
            if next + 1 < body.endIndex, body[next] == 0x2D, body[next + 1] == 0x2D { break }
            // Skip the rest of the delimiter line.
            while next < body.endIndex, body[next] != 0x0A { next += 1 }
            partStart = next < body.endIndex ? body.index(after: next) : body.endIndex
            searchStart = partStart ?? body.endIndex
        }
        return parts
    }

    func decodedText() -> String? {
        let encoding = headers["content-transfer-encoding"]?.lowercased() ?? ""
        let raw: Data
        switch encoding {
        case "base64":
            let compact = String(lossyUTF8: body).filter { !$0.isWhitespace }
            guard let decoded = Data(base64Encoded: compact, options: .ignoreUnknownCharacters) else { return nil }
            raw = decoded
        case "quoted-printable":
            raw = Self.decodeQuotedPrintable(body)
        default:
            raw = body
        }
        return Self.string(from: raw, charset: parameter("charset", of: "content-type"))
    }

    static func decodeQuotedPrintable(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var output = [UInt8]()
        output.reserveCapacity(bytes.count)
        var index = 0
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: return byte - 0x30
            case 0x41...0x46: return byte - 0x37
            case 0x61...0x66: return byte - 0x57
            default: return nil
            }
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x3D {  // "="
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A { index += 2; continue }  // Soft break.
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A { index += 3; continue }
                if index + 2 < bytes.count, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                    output.append(high << 4 | low)
                    index += 3
                    continue
                }
            }
            output.append(byte)
            index += 1
        }
        return Data(output)
    }

    /// Decodes with the declared charset, falling back to UTF-8 and then Latin-1 (which accepts any
    /// byte sequence), so a mislabeled message still yields text.
    static func string(from data: Data, charset: String?) -> String? {
        if let charset {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
                if let decoded = String(data: data, encoding: encoding) { return decoded }
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}
