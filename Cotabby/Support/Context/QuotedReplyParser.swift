import Foundation

/// File overview:
/// Finds the message a mail reply answers, in the text below the caret of the reply being written.
///
/// Why: when the user replies in Mail or Outlook, the compose body holds their (empty) reply, their
/// signature, then the quoted original. Cotabby already reads that text through Accessibility
/// (`FocusedInputSnapshot.trailingText`), so the message being answered is right there, fresher
/// than any sync.
///
/// Two readers, for two different jobs:
/// - `quotedMessage` and `quotedSubject` are the one reader of "what was the incoming message": what
///   an answer replies to, its sender, subject and date, and the addressee and subject a suggestion
///   names. They read the client's quote header only through `MailQuoteHeader` (normalized text,
///   nothing header-like above the caret, the first header anchored at a quote boundary, exactly
///   one sender address, no quoted-printable or HTML remnants). What they read is data about the
///   message; it never chooses which conversation memory or an answer searches.
/// - `headerRange` and `looseMessage` only reformat text that goes into a prompt anyway (the
///   condensed thread, `MailReplyContext.condensedThread`): they find every older quote in a thread,
///   which the strict reader deliberately refuses, and decide nothing.
///
/// Pure and shared: `MailReplyContext` for suggestions, `ReplyFieldEmptiness` and
/// `IncomingMessageResolver` for answers.
nonisolated enum QuotedReplyParser {
    struct QuotedMessage: Equatable, Sendable {
        /// The original's sender as the header names them, when it does.
        let sender: String?
        let body: String
        /// The sender's address the header carries, lowercased: part of the message's identity.
        var senderAddress: String?
        /// When it was sent, as the header gives it: an Outlook block's "Sent:"/"Date:" value, or an
        /// attribution line ("On Mon, 3 Oct 2026 at 10:15, … wrote:"). Part of a message's identity.
        var sentLine: String?
        /// The subject an Outlook-style block names; attribution quotes name none.
        var subject: String?
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

    /// The message the client quoted below the caret, read through the strict shared parser; nil
    /// when there is no header that parser accepts.
    static func quotedMessage(precedingText: String = "", trailingText: String) -> QuotedMessage? {
        guard let header = MailQuoteHeader.client(precedingText: precedingText, trailingText: trailingText) else { return nil }
        let fields: [HeaderField] = header.isAttribution ? [] : header.lines.compactMap(headerField)
        let attribution = header.lines.joined(separator: " ")
        let sender = header.isAttribution
            ? senderName(fromAttribution: attribution)
            : fields.first { ["from", "gönderen", "kimden"].contains($0.name) }.flatMap { cleanName($0.value) }
        let sentLine = header.isAttribution
            ? attribution
            : fields.first { ["sent", "date", "gönderildi", "tarih"].contains($0.name) }?.value
        let subject = fields.first { ["subject", "konu"].contains($0.name) }?.value
        let body = header.bodyLines.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return QuotedMessage(
            sender: sender, body: String(body.prefix(maximumBodyCharacters)), senderAddress: header.senderAddress,
            sentLine: sentLine, subject: subject.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    static func quotedMessage(in text: String) -> QuotedMessage? {
        quotedMessage(precedingText: "", trailingText: text)
    }

    /// The subject the client's quote header names ("Subject: Re: Q3 rollout plan"), through the
    /// strict parser; nil for attribution quotes, which name no subject.
    static func quotedSubject(precedingText: String = "", in text: String) -> String? {
        quotedMessage(precedingText: precedingText, trailingText: text)?.subject
    }

    /// Any quoted message starting at `text`'s first header, read loosely: for reformatting a
    /// thread the prompt carries anyway, never for a decision (see the file overview).
    static func looseMessage(in text: String) -> QuotedMessage? {
        guard let header = headerRange(in: text) else { return nil }
        let headerLine = String(text[header])
        var bodyStart = header.upperBound
        var sender = senderName(fromAttribution: headerLine)
        var senderAddress = address(in: headerLine)
        var sentLine: String? = sender == nil ? nil : headerLine.trimmingCharacters(in: .whitespaces)

        // Outlook-style block: From / Sent / To / Cc / Subject lines, then the body.
        if sender == nil || headerLine.range(of: "original message", options: .caseInsensitive) != nil {
            let block = headerBlock(in: String(text[header.lowerBound...]))
            sender = block.sender.flatMap(cleanName) ?? sender
            senderAddress = block.sender.flatMap(address) ?? senderAddress
            sentLine = block.sent ?? sentLine
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
        return QuotedMessage(
            sender: sender, body: String(cleaned.prefix(maximumBodyCharacters)), senderAddress: senderAddress, sentLine: sentLine
        )
    }

    /// What an Outlook-style block's field lines say, and how much of the text they take.
    private struct HeaderBlock {
        /// The raw From value ("Ayşe <a@example.com>").
        let sender: String?
        /// The raw Sent/Date value.
        let sent: String?
        /// Characters the rule and field lines (plus the blank line after them) take, so the body
        /// starts right after.
        let consumedCharacters: Int
    }

    private static func headerBlock(in blockText: String) -> HeaderBlock {
        var sender: String?
        var sent: String?
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
                if ["from", "gönderen", "kimden"].contains(field.name) { sender = field.value }
                if ["sent", "date", "gönderildi", "tarih"].contains(field.name) { sent = field.value }
                consumed += line.count + 1
            } else if !sawField {
                consumed += line.count + 1  // The rule line itself.
            } else {
                break
            }
        }
        return HeaderBlock(sender: sender, sent: sent, consumedCharacters: min(consumed, blockText.count))
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

    /// The address in a sender's text ("Ayşe <ayse@example.com>", "On …, Ayşe <a@x> wrote:", or a bare
    /// "a@example.com"), lowercased; nil when there is none.
    static func address(in raw: String) -> String? {
        if let open = raw.lastIndex(of: "<"), let close = raw[open...].firstIndex(of: ">") {
            let inside = raw[raw.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            return inside.contains("@") ? inside.lowercased() : nil
        }
        let bare = raw.trimmingCharacters(in: .whitespaces)
        return bare.contains("@") && !bare.contains(" ") ? bare.lowercased() : nil
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
