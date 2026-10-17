import Foundation

/// File overview:
/// Finds the quote header a mail client put under the reply being written, strictly enough that
/// text someone typed or pasted is never read in its place.
///
/// What it is for: reading what the quoted message says (who sent it, when, its subject and its
/// text), as data for a prompt or for an answer to that message. It never chooses which
/// conversation memory searches: a quote is written by its sender, so conversation memory gives a
/// mail no scope from it at all (`ConversationScopeResolver`).
///
/// In the field, everything below the client's header is the other person's text, and everything
/// above it is the user's draft (including anything they pasted). The client writes "On … Ayşe
/// <ayse@example.com> wrote:" (Apple Mail, Gmail; "… tarihinde … yazdı:" in Turkish) or a
/// "From: / Sent: / To: / Cc: / Subject:" block (Outlook). A header is accepted only when it is the
/// first header-like thing in the whole field:
/// - The text is normalized first (CRLF and other line breaks, NFKC, so fullwidth "＠" is "@", and
///   invisible format characters such as zero-width and bidi marks removed), so a header cannot
///   hide from these checks or be disguised as one.
/// - Nothing above the caret may look like a header or a quote ("> …"): the reply must be written
///   above the quote. An inline reply, or a header pasted into the draft, gives none.
/// - The first header-like line after the caret must be one this parser reads, at the quote
///   boundary (the field's start, a blank line or a separator line above it).
/// - An "On … wrote:" header names exactly one address, and a From line exactly one: a display
///   name that carries an address is someone's text inside the header.
/// - Quoted-printable or HTML remnants in the header, or a second header-like block right after it,
///   are ambiguous: none.
///
/// Pure; read through `QuotedReplyParser.quotedMessage`, the one reader every decision about a
/// quoted message uses.
nonisolated enum MailQuoteHeader {
    struct Header: Equatable, Sendable {
        /// The header's own lines, normalized: the attribution (one to three lines), or the
        /// "From: …" block up to the blank line after it.
        let lines: [String]
        /// The sender's one address: the attribution's, or the From line's, lowercased.
        let senderAddress: String
        /// Whether it is an "On … wrote:" attribution rather than a "From:" block.
        let isAttribution: Bool
        /// The lines between the caret and the header (the user's signature, blank lines).
        let linesAboveHeader: [String]
        /// The quoted message's lines after the header, "> " marks removed, up to the next
        /// header-like line (an older message).
        let bodyLines: [String]
    }

    /// Lines after the caret searched for the quote header, and lines a header block may have
    /// (From, Sent, To, Cc, Subject, folded continuations).
    static let searchLines = 60
    static let maximumHeaderBlockLines = 12
    /// Text before the caret looked through (UTF-16 units). Longer means no header: something
    /// header-like up there could not be ruled out.
    static let maximumPrecedingUTF16 = 50_000

    private static let address = try? NSRegularExpression(pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)
    /// A header field in any language: a short label, a colon, then something with an address
    /// ("Von: …", "De : …", "Kimden: …").
    private static let headerField = try? NSRegularExpression(pattern: #"^\p{L}[\p{L}\p{M} .-]{0,24}:\s.*@"#)
    /// A quoted-printable escape ("=C5=9F", "=3D").
    private static let quotedPrintable = try? NSRegularExpression(pattern: #"=[0-9A-F]{2}"#)

    /// The client's quote header below the caret, or nil whenever it cannot be told apart from text
    /// someone typed.
    static func client(precedingText: String, trailingText: String) -> Header? {
        guard precedingText.utf16.count <= maximumPrecedingUTF16 else { return nil }
        let above = normalizedLines(precedingText)
        let below = normalizedLines(String(trailingText.prefix(8000)))
        // The caret's line is split between the two; it counts as below the caret.
        let caretLine = above.count - 1
        var lines = Array(above.dropLast())
        lines.append((above.last ?? "") + (below.first ?? ""))
        lines += below.dropFirst().prefix(searchLines)
        guard !lines[..<caretLine].contains(where: looksLikeHeaderOrQuote) else { return nil }
        guard let start = lines[caretLine...].firstIndex(where: looksLikeHeaderOrQuote),
              isQuoteHeaderStart(lines[start]), !lines[start].hasPrefix(">"),
              start == 0 || isBoundary(lines[start - 1]) else { return nil }

        let header: [String]
        let end: Int
        let isAttribution = isAttributionLine(lines[start])
        if isAttribution {
            // "On … wrote:" may wrap; it ends at the line that says "wrote:" / "yazdı:".
            end = lines[start...].prefix(3).firstIndex { endsAttribution($0) } ?? start
            header = Array(lines[start...end])
        } else {
            header = Array(lines[start...].prefix(maximumHeaderBlockLines).prefix { !$0.isEmpty })
            end = start + header.count - 1
        }
        // Exactly one address names the sender: in the whole attribution, or on the From line.
        let senderAddresses = addresses(in: isAttribution ? header.joined(separator: " ") : header[0])
        guard senderAddresses.count == 1, let senderAddress = senderAddresses.first,
              !lines[start...end].contains(where: hasEncodingRemnant) else { return nil }
        if let next = lines[(end + 1)...].first(where: { !isBoundary($0) }),
           !next.hasPrefix(">"), looksLikeHeaderOrQuote(next) { return nil }
        return Header(
            lines: header, senderAddress: senderAddress, isAttribution: isAttribution,
            linesAboveHeader: Array(lines[caretLine..<start]), bodyLines: quotedBody(after: end, in: lines)
        )
    }

    /// The message's own lines after its header, quote marks removed, up to the next header-like line.
    private static func quotedBody(after end: Int, in lines: [String]) -> [String] {
        var body: [String] = []
        for line in lines[(end + 1)...] {
            let unquoted = String(line.drop { $0 == ">" || $0 == " " })
            if looksLikeHeaderOrQuote(unquoted) { break }
            body.append(unquoted)
        }
        return body
    }

    /// Lines with every line break unified, NFKC applied, invisible format characters (zero-width,
    /// bidi controls, soft hyphens: Unicode category Cf) removed, and outer spaces trimmed.
    static func normalizedLines(_ text: String) -> [String] {
        var scalars = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            defer { previousWasCR = scalar == "\r" }
            switch scalar {
            case "\n":
                if !previousWasCR { scalars.append("\n") }
            case "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}":
                scalars.append("\n")
            default:
                if scalar.properties.generalCategory != .format { scalars.append(scalar) }
            }
        }
        return String(scalars).precomposedStringWithCompatibilityMapping
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Anything a header could be confused with: a quote line, a header this parser reads, a header
    /// field in another language, or a line naming an address and ending in a colon (an
    /// attribution in another language).
    private static func looksLikeHeaderOrQuote(_ line: String) -> Bool {
        if line.hasPrefix(">") || isQuoteHeaderStart(line) { return true }
        guard line.contains("@") else { return false }
        if line.hasSuffix(":"), !addresses(in: line).isEmpty { return true }
        guard let headerField else { return false }
        return headerField.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// A blank line or a separator line ("____", "-----Original Message-----" style rules).
    private static func isBoundary(_ line: String) -> Bool {
        line.isEmpty || (line.count >= 3 && line.allSatisfy { "_-=—–*".contains($0) })
            || line.lowercased().hasPrefix("-----original message")
    }

    private static let encodingMarkers: [String] = ["&lt;", "&gt;", "&amp;", "&#", "<br", "<div", "</", "=?utf-8?", "=?iso-"]

    /// Quoted-printable or HTML left in the text: the field is not showing the header as the client
    /// wrote it.
    private static func hasEncodingRemnant(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if encodingMarkers.contains(where: { lowered.contains($0) }) || lowered.hasSuffix("=") { return true }
        guard let quotedPrintable else { return false }
        return quotedPrintable.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static func isQuoteHeaderStart(_ line: String) -> Bool {
        isAttributionLine(line) || line.lowercased().hasPrefix("from:")
    }

    /// "On … wrote:" (or an "On …" line naming an address, whose "wrote:" wraps onto the next line),
    /// or Turkish "… tarihinde … yazdı:".
    private static func isAttributionLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered.hasPrefix("on ") { return lowered.contains("wrote:") || lowered.contains("@") }
        return lowered.contains(" tarihinde ")
    }

    private static func endsAttribution(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return lowered.hasSuffix("wrote:") || lowered.hasSuffix("yazdı:")
    }

    private static func addresses(in text: String) -> Set<String> {
        guard let address else { return [] }
        let matches = address.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return Set(matches.compactMap { Range($0.range, in: text).map { text[$0].lowercased() } })
    }
}
