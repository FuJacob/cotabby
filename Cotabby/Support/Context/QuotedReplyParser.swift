import Foundation

/// File overview:
/// Finds the message a mail reply answers, in the text below the caret of the reply being written.
///
/// Why: when the user replies in Mail or Outlook, the compose body holds their (empty) reply, their
/// signature, then the quoted original. Cotabby already reads that text through Accessibility
/// (`FocusedInputSnapshot.trailingText`), so the message being answered is right there, fresher
/// than any sync. This parses it out: the quote header in the forms common mail clients write
/// (English and Turkish attribution lines, Outlook's "From:/Gönderen:" block, "Original Message"
/// rules), the sender named in it, the thread's subject, and the quoted body up to the next, older
/// quote.
///
/// Pure and shared: `MailReplyContext` reads a reply's subject, recipient and condensed thread
/// through it for suggestions, and answers read the question being answered through it.
nonisolated enum QuotedReplyParser {
    struct QuotedMessage: Equatable, Sendable {
        /// The original's sender as the header names them, when it does.
        let sender: String?
        let body: String
    }

    /// One "Name: value" line of an Outlook-style header block.
    private struct HeaderField {
        let name: String
        let value: String
    }

    static let maximumBodyCharacters = 2000

    private static let attribution = try? NSRegularExpression(
        pattern: #"(?im)^(?:>\s*)?(on\s.{3,200}?wrote:|.{0,200}?tarihinde\s.{0,120}?yazdı:)\s*$"#
    )
    private static let outlookBlock = try? NSRegularExpression(
        pattern: #"(?im)^(?:from|gönderen|kimden)\s*:\s*(.+)$"#
    )
    private static let originalMessageRule = try? NSRegularExpression(
        pattern: #"(?im)^-{2,}\s*(?:original message|orijinal ileti|özgün ileti)\s*-{2,}\s*$"#
    )

    /// Where the first quote header starts in `text`, if there is one.
    static func headerRange(in text: String) -> Range<String.Index>? {
        let whole = NSRange(text.startIndex..., in: text)
        return [attribution, originalMessageRule, outlookBlock].compactMap { $0 }
            .compactMap { $0.firstMatch(in: text, range: whole).flatMap { Range($0.range, in: text) } }
            .min { $0.lowerBound < $1.lowerBound }
    }

    static func quotedMessage(in text: String) -> QuotedMessage? {
        guard let header = headerRange(in: text) else { return nil }
        let headerLine = String(text[header])
        var bodyStart = header.upperBound
        var sender = senderName(fromAttribution: headerLine)

        // Outlook-style block: From / Sent / To / Cc / Subject lines, then the body.
        if sender == nil || headerLine.range(of: "original message", options: .caseInsensitive) != nil {
            let block = headerBlock(in: String(text[header.lowerBound...]))
            sender = block.sender ?? sender
            bodyStart = text.index(header.lowerBound, offsetBy: block.consumedCharacters)
        }

        var body = String(text[bodyStart...])
        // Only the latest quoted message: stop at the next, older header.
        if let next = headerRange(in: body) { body = String(body[..<next.lowerBound]) }
        let lines = body.components(separatedBy: .newlines).map { line -> String in
            var trimmed = Substring(line)
            while trimmed.first == ">" || trimmed.first == " " { trimmed = trimmed.dropFirst() }
            return String(trimmed)
        }
        let cleaned = lines.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return QuotedMessage(sender: sender, body: String(cleaned.prefix(maximumBodyCharacters)))
    }

    /// The sender an Outlook-style block names, and how many characters of `blockText` its rule and
    /// field lines (plus the blank line after them) take, so the body starts right after.
    private static func headerBlock(in blockText: String) -> (sender: String?, consumedCharacters: Int) {
        var sender: String?
        var consumed = 0
        var sawField = false
        for line in blockText.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty && sawField {
                consumed += line.count + 1
                break
            }
            if let field = headerField(trimmed) {
                sawField = true
                if ["from", "gönderen", "kimden"].contains(field.name) { sender = cleanName(field.value) }
                consumed += line.count + 1
            } else if !sawField {
                consumed += line.count + 1  // The rule line itself.
            } else {
                break
            }
        }
        return (sender, min(consumed, blockText.count))
    }

    /// The subject named in the first Outlook-style quote block ("Subject: Re: Q3 rollout plan"),
    /// read from the block's own field lines only, so a "Subject:" line in the user's draft above
    /// the quote is never taken for it. Nil for attribution quotes ("On …, X wrote:"), which name no
    /// subject.
    static func quotedSubject(in text: String) -> String? {
        guard let header = headerRange(in: text) else { return nil }
        var sawField = false
        for line in text[header.lowerBound...].components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A blank line after the fields ends the block; the quoted message starts there.
            if trimmed.isEmpty {
                if sawField { return nil }
                continue
            }
            guard let field = headerField(trimmed) else {
                // The rule line opens the block; any other line ends it.
                if originalMessageRule?.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
                    continue
                }
                return nil
            }
            sawField = true
            if ["subject", "konu"].contains(field.name) { return field.value.isEmpty ? nil : field.value }
        }
        return nil
    }

    /// "On Mon, 3 Oct 2026 at 10:15, Ayşe Yılmaz <ayse@example.com> wrote:" → "Ayşe Yılmaz";
    /// "3 Eki 2026 tarihinde Ayşe Yılmaz şunu yazdı:" → "Ayşe Yılmaz".
    static func senderName(fromAttribution line: String) -> String? {
        let text = line.trimmingCharacters(in: CharacterSet(charactersIn: "> ").union(.whitespaces))
        if let range = text.range(of: #"(?i)tarihinde\s+(.+?)\s+(?:şunu\s+)?yazdı:"#, options: .regularExpression) {
            let inner = String(text[range])
                .replacingOccurrences(of: #"(?i)^tarihinde\s+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)\s+(?:şunu\s+)?yazdı:$"#, with: "", options: .regularExpression)
            return cleanName(inner)
        }
        guard text.lowercased().hasSuffix("wrote:") else { return nil }
        var head = String(text.dropLast("wrote:".count)).trimmingCharacters(in: .whitespaces)
        if head.lowercased().hasPrefix("on ") { head = String(head.dropFirst(3)) }
        // The name follows the last comma of the date ("Mon, 3 Oct 2026 at 10:15, Ayşe <a@x>").
        let candidate = head.components(separatedBy: ",").last ?? head
        return cleanName(candidate)
    }

    private static let headerFieldNames: Set<String> = [
        "from", "sent", "date", "to", "cc", "subject", "gönderen", "kimden", "gönderildi", "tarih", "kime", "bilgi", "konu"
    ]

    private static func headerField(_ line: String) -> HeaderField? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        guard headerFieldNames.contains(name) else { return nil }
        return HeaderField(name: name, value: String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
    }

    /// A display name without its address ("Ayşe <a@example.com>" → "Ayşe"), or the address alone.
    private static func cleanName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespaces)
        if let open = name.firstIndex(of: "<") {
            let address = name[name.index(after: open)...].trimmingCharacters(in: CharacterSet(charactersIn: "> "))
            name = String(name[..<open]).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            if name.isEmpty { name = address }
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        return name.isEmpty ? nil : name
    }
}
