import Foundation

/// File overview:
/// Pure rules for conversation memory on the Swift side: which conversation the focused field
/// belongs to, what to search memory for, and how retrieved messages read in a prompt.
///
/// Why pure and separate: these decide what private history may reach a prompt, so each rule is
/// stated once here, without AppKit or the engine, and pinned by tests. The retriever
/// (`MemoryRetriever`) only applies them.

/// The conversation a field belongs to: what memory's search is scoped to.
nonisolated struct ConversationScope: Equatable, Hashable, Sendable {
    /// The chat name or mail subject as the app shows it; memory matches it within `sources`.
    let title: String
    /// The memory sources that serve the focused app (`whatsapp` for WhatsApp, `apple_mail` for
    /// Mail). Title matching never crosses into other apps' history.
    let sources: [String]
    /// For mail: the addresses in the quote header below the caret. Without the user's own
    /// addresses they must be exactly the matched thread's people, so a mail to other people that
    /// happens to share a subject never gets this thread (`MemoryEngine.Scope.requiredParticipants`).
    var requiredParticipants: Set<String> = []
}

nonisolated enum ConversationScopeResolver {
    /// The scope for a focused field, or nil when memory has nothing to say about it: the app has no
    /// enabled memory source, or the window does not name a conversation.
    ///
    /// The title is the focused field's window title (`FocusedInputContext.windowTitle`). In Mail a
    /// compose window's title is the message subject ("Re: Project results"), which memory matches
    /// to the thread with reply prefixes removed; Teams' title is parsed for the open chat.
    ///
    /// A subject alone does not say who the mail is for: "Invoice" to one customer must not draw on
    /// the "Invoice" thread with another. So a mail gets memory only when it is a reply or forward
    /// (its title carries the prefix) and the client's quote header (the first header in the whole
    /// field, `precedingText` then `trailingText`) names an address; the thread must have exactly
    /// those people (`requiredParticipants`).
    static func scope(
        bundleIdentifier: String,
        conversationTitle: String?,
        precedingText: String = "",
        trailingText: String = "",
        sourcesByBundle: [String: [String]]
    ) -> ConversationScope? {
        let raw = conversationTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let named = teamsBundleIdentifiers.contains(bundleIdentifier) ? teamsConversationTitle(raw) : raw
        guard let sources = sourcesByBundle[bundleIdentifier], !sources.isEmpty,
              let title = named, !title.isEmpty,
              !genericTitles.contains(title.lowercased()) else { return nil }
        guard mailBundleIdentifiers.contains(bundleIdentifier) else {
            return ConversationScope(title: title, sources: sources)
        }
        let quoted = quotedAddresses(precedingText: precedingText, trailingText: trailingText)
        guard hasReplyPrefix(title), !quoted.isEmpty else { return nil }
        return ConversationScope(title: title, sources: sources, requiredParticipants: quoted)
    }

    static let mailBundleIdentifiers: Set<String> = ["com.apple.mail", "com.microsoft.Outlook"]

    private static let replyPrefix = try? NSRegularExpression(
        pattern: #"^\s*(re|fw|fwd|aw|wg|sv|ynt|ilt|tr)\s*(\[\d+\])?\s*:"#, options: .caseInsensitive
    )

    /// Whether a subject starts with a reply or forward prefix ("Re:", "FW:", "AW [2]:", "YNT:").
    static func hasReplyPrefix(_ subject: String) -> Bool {
        guard let replyPrefix else { return false }
        let range = NSRange(subject.startIndex..., in: subject)
        return replyPrefix.firstMatch(in: subject, range: range) != nil
    }

    private static let address = try? NSRegularExpression(pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)
    /// A header field in any language: a short label, a colon, then something with an address
    /// ("Von: …", "De : …", "Kimden: …").
    private static let headerField = try? NSRegularExpression(pattern: #"^\p{L}[\p{L}\p{M} .-]{0,24}:\s.*@"#)

    /// Lines after the caret searched for the quote header, and lines a header block may have
    /// (From, Sent, To, Cc, Subject, folded continuations).
    static let quoteHeaderSearchLines = 60
    static let maximumHeaderBlockLines = 12
    /// Text before the caret looked through (UTF-16 units). Longer means no memory: something
    /// header-like up there could not be ruled out.
    static let maximumPrecedingUTF16 = 50_000

    /// The addresses in the quote header the mail client put under the reply being written,
    /// lowercased; empty whenever that header cannot be told apart from text someone typed.
    ///
    /// In the field, everything below the client's header is the other person's text, and
    /// everything above it is the user's draft (including anything they pasted). The client writes
    /// "On … Ayşe <ayse@example.com> wrote:" (Apple Mail, Gmail; "… tarihinde … yazdı:" in
    /// Turkish) or a "From: / Sent: / To: / Cc: / Subject:" block (Outlook). A header is accepted
    /// only when it is the first header-like thing in the whole field, so text that could pass for
    /// one is never read in its place:
    /// - The text is normalized first (CRLF and other line breaks, NFKC, so fullwidth "＠" is "@",
    ///   and invisible format characters such as zero-width and bidi marks removed), so a header
    ///   cannot hide from these checks or be disguised as one.
    /// - Nothing above the caret may look like a header or a quote ("> …"): the reply must be
    ///   written above the quote. An inline reply, or a header pasted into the draft, gives none.
    /// - The first header-like line after the caret must be one this parser reads, at the quote
    ///   boundary (the field's start, a blank line or a separator line above it). A header in
    ///   another language, a quote line, or an address line ending in a colon coming first means
    ///   the client's header is not the one found, so none.
    /// - An "On … wrote:" header names exactly one address, and a From line exactly one: a display
    ///   name that carries an address is someone's text inside the header.
    /// - Quoted-printable or HTML remnants in the header, or a second header-like block right after
    ///   it, are ambiguous: none.
    static func quotedAddresses(precedingText: String, trailingText: String) -> Set<String> {
        guard precedingText.utf16.count <= maximumPrecedingUTF16 else { return [] }
        let above = normalizedLines(precedingText)
        let below = normalizedLines(String(trailingText.prefix(8000)))
        // The caret's line is split between the two; it counts as below the caret.
        let caretLine = above.count - 1
        var lines = Array(above.dropLast())
        lines.append((above.last ?? "") + (below.first ?? ""))
        lines += below.dropFirst().prefix(quoteHeaderSearchLines)
        guard !lines[..<caretLine].contains(where: looksLikeHeaderOrQuote) else { return [] }
        guard let start = lines[caretLine...].firstIndex(where: looksLikeHeaderOrQuote),
              isQuoteHeaderStart(lines[start]), !lines[start].hasPrefix(">"),
              start == 0 || isBoundary(lines[start - 1]) else { return [] }

        let header: [String]
        let end: Int
        if isAttributionLine(lines[start]) {
            // "On … wrote:" may wrap; it ends at the line that says "wrote:" / "yazdı:".
            end = lines[start...].prefix(3).firstIndex { endsAttribution($0) } ?? start
            header = Array(lines[start...end])
            guard addresses(in: header.joined(separator: " ")).count == 1 else { return [] }
        } else {
            let block = Array(lines[start...].prefix(maximumHeaderBlockLines).prefix { !$0.isEmpty })
            end = start + block.count - 1
            guard addresses(in: block[0]).count == 1 else { return [] }
            header = block.filter(isAddressHeaderLine)
        }
        guard !lines[start...end].contains(where: hasEncodingRemnant) else { return [] }
        if let next = lines[(end + 1)...].first(where: { !isBoundary($0) }),
           !next.hasPrefix(">"), looksLikeHeaderOrQuote(next) { return [] }
        return addresses(in: header.joined(separator: " "))
    }

    /// The quote header's addresses when the caret is at the very start of the reply (tests and
    /// callers without the text above the caret).
    static func quotedAddresses(in trailingText: String) -> Set<String> {
        quotedAddresses(precedingText: "", trailingText: trailingText)
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

    /// Anything a header could be confused with: a quote line, a header this parser reads, a
    /// header field in another language, or a line naming an address and ending in a colon (an
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

    /// Quoted-printable or HTML left in the text: the field is not showing the header as the
    /// client wrote it.
    private static func hasEncodingRemnant(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if ["&lt;", "&gt;", "&amp;", "&#", "<br", "<div", "</", "=?utf-8?", "=?iso-"].contains(where: { lowered.contains($0) })
            || lowered.hasSuffix("=") { return true }
        guard let quotedPrintable else { return false }
        return quotedPrintable.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// A quoted-printable escape ("=C5=9F", "=3D").
    private static let quotedPrintable = try? NSRegularExpression(pattern: #"=[0-9A-F]{2}"#)

    /// A From, To or Cc line of an Outlook-style header block (not Sent or Subject).
    private static func isAddressHeaderLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return lowered.hasPrefix("from:") || lowered.hasPrefix("to:") || lowered.hasPrefix("cc:")
    }

    private static func isQuoteHeaderStart(_ line: String) -> Bool {
        isAttributionLine(line) || line.lowercased().hasPrefix("from:")
    }

    /// "On … wrote:" (or an "On …" line naming an address, whose "wrote:" wraps onto the next
    /// line), or Turkish "… tarihinde … yazdı:".
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

    static let teamsBundleIdentifiers: Set<String> = ["com.microsoft.teams2", "com.microsoft.teams"]

    /// The chat or meeting name in a Teams window title. Teams titles its window
    /// "<view> | <conversation> | <organization> | <account> | Microsoft Teams"
    /// ("Chat | Sam Rivera | example.com | alex@example.com | Microsoft Teams"); the conversation is
    /// the first part that is not the view, the app, or the signed-in account. Nil when the window
    /// shows no conversation (only a view such as "Activity").
    static func teamsConversationTitle(_ windowTitle: String) -> String? {
        var parts = windowTitle.components(separatedBy: " | ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("@") && $0.lowercased() != "microsoft teams" }
        if let first = parts.first, teamsViews.contains(first.lowercased()) {
            parts.removeFirst()
        }
        // A lone remaining part with a dot and no space is the organization's domain, not a chat.
        guard let title = parts.first, !(title.contains(".") && !title.contains(" ")) else { return nil }
        return title
    }

    /// Teams' left-rail views, as they prefix the window title (English and Turkish).
    static let teamsViews: Set<String> = [
        "chat", "activity", "teams", "calendar", "calls", "files", "meet", "apps", "onedrive",
        "sohbet", "etkinlik", "ekipler", "takvim", "aramalar", "dosyalar", "uygulamalar"
    ]

    /// Window titles that name an app or an empty compose window, not a conversation.
    static let genericTitles: Set<String> = [
        "whatsapp", "mail", "new message", "yeni ileti", "untitled", "slack", "microsoft teams", "outlook"
    ]

    /// The search text for a field: complete 8-word blocks of what has been typed (so the query, and
    /// with it the cached result, stays the same while a block is being typed), or the conversation
    /// title alone before the first block exists, which already finds the conversation's recent
    /// context.
    static func query(precedingText: String, scope: ConversationScope) -> String {
        let stable = TypingHistoryQuery.stableText(from: precedingText)
        return stable.isEmpty ? scope.title : stable
    }
}

/// Turns retrieved messages into prompt lines.
nonisolated enum MemorySnippetFormatter {
    /// Characters per message line, and for the whole section (the renderer's budget).
    static let maximumLineCharacters = 240
    static let maximumTotalCharacters = 900

    struct Message: Equatable, Sendable {
        let sender: String
        let isFromMe: Bool
        let timestamp: Date
        let text: String
    }

    /// Oldest first, so the lines read like the conversation they came from; each line dated and
    /// attributed ("12 Sep · Ayşe: the invoice is paid") so the model can tell who said what.
    static func lines(_ messages: [Message], calendar: Calendar = .current) -> [String] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM"
        var lines: [String] = []
        var total = 0
        for message in messages.sorted(by: { $0.timestamp < $1.timestamp }) {
            let text = message.text.split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let clipped = text.count > maximumLineCharacters ? String(text.prefix(maximumLineCharacters)) + "…" : text
            let speaker = message.isFromMe ? "You" : speakerName(message.sender)
            let line = "\(formatter.string(from: message.timestamp)) · \(speaker): \(clipped)"
            guard total + line.count <= maximumTotalCharacters else { continue }
            total += line.count + 1
            lines.append(line)
        }
        return lines
    }

    static let maximumSenderCharacters = 40

    /// Someone else's name as a line's speaker. Names come from other people's apps, so one can
    /// never start a new line, run long, or pass for the user ("You").
    static func speakerName(_ sender: String) -> String {
        let collapsed = sender.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        let name = collapsed.isEmpty ? "Someone" : String(collapsed.prefix(maximumSenderCharacters))
        return name.lowercased() == "you" ? "\(name) (contact)" : name
    }
}
