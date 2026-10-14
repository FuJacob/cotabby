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
    /// (its title carries the prefix) and the client's quote header below the caret (`trailingText`)
    /// names an address; the thread must have exactly those people (`requiredParticipants`).
    static func scope(
        bundleIdentifier: String,
        conversationTitle: String?,
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
        let quoted = quotedAddresses(in: trailingText)
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

    /// Lines of the text after the caret searched for the quote header, and lines a header block
    /// may have (From, Sent, To, Cc, Subject, folded continuations).
    static let quoteHeaderSearchLines = 60
    static let maximumHeaderBlockLines = 12

    /// The addresses in the quote header of the message being answered, lowercased.
    ///
    /// Everything below the caret in a reply was written by the other person, except the header
    /// the mail client puts above the quote: "On … Ayşe <ayse@example.com> wrote:" (Apple Mail,
    /// Gmail; "… tarihinde … yazdı:" in Turkish) or a "From: / Sent: / To: / Cc: / Subject:"
    /// block (Outlook). Only the first such header is read: a "From:" line or an address further
    /// down is the sender's own text, and a sender must not be able to name another thread's
    /// people there and so pull that thread's memory into a reply to them.
    static func quotedAddresses(in trailingText: String) -> Set<String> {
        let lines = trailingText.prefix(8000)
            .split(separator: "\n", maxSplits: quoteHeaderSearchLines, omittingEmptySubsequences: false)
            .prefix(quoteHeaderSearchLines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.firstIndex(where: isQuoteHeaderStart) else { return [] }
        let header: [String]
        if isAttributionLine(lines[start]) {
            // "On … wrote:" may wrap; it ends at the line that says "wrote:" / "yazdı:".
            let end = lines[start...].prefix(3).firstIndex { endsAttribution($0) } ?? start
            header = Array(lines[start...end])
        } else {
            let block: [String] = Array(lines[start...].prefix(maximumHeaderBlockLines).prefix { !$0.isEmpty })
            header = block.filter(isAddressHeaderLine)
        }
        return addresses(in: header.joined(separator: " "))
    }

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
