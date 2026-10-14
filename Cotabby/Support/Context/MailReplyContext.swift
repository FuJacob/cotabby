import Foundation

/// File overview:
/// Pure rules for writing a reply in a mail app (Outlook, Mail, Spark, Airmail).
///
/// A reply is the one surface where the most relevant context sits *after* the caret: the quoted
/// thread being answered. Treated like any other field, a reply missed that thread:
/// - the prompt passed ~200 characters of text after the caret, which in a reply is only the quoted
///   header's From/Date/To lines, never what was said;
/// - Outlook's inline reply lives in its main window, titled after the open folder ("Inbox • All
///   Accounts"), which the prompt then named as the surface;
/// - the screen excerpt kept the message list beside the composer, whose previews of other mail the
///   model then copied;
/// - nothing named who the reply is addressed to, so a salutation completed to whichever name the
///   prompt showed most, often the user's own.
///
/// The thread's own header names the conversation ("Subject: Re: Q3 rollout plan") and its sender,
/// and its text already arrives through Accessibility as the field's trailing text, so these rules
/// read all of it from there; the header itself is parsed by `QuotedReplyParser`. What they read is
/// message content its sender wrote: it shapes the prompt, but it never chooses which conversation
/// memory searches (that is `ConversationScopeResolver`'s rule). Kept pure so each rule is pinned by
/// tests without AX, OCR or the memory engine. Used by `SuggestionRequestFactory`,
/// `ScreenshotContextGenerator` and answers' `IncomingMessageResolver`.
nonisolated enum MailReplyContext {
    /// Characters after the caret a mail prompt carries: the quoted header plus the start of the
    /// message being answered. Other surfaces keep the configured default, where text after the
    /// caret is the rest of the user's own paragraph.
    static let trailingCharacters = 1500

    static func isMail(bundleIdentifier: String?) -> Bool {
        AppSurfaceClassifier.classify(bundleIdentifier: bundleIdentifier) == .email
    }

    /// The trailing-text budget for a field: `trailingCharacters` in a mail app, else the default.
    static func trailingBudget(bundleIdentifier: String?, defaultBudget: Int) -> Int {
        isMail(bundleIdentifier: bundleIdentifier) ? max(defaultBudget, trailingCharacters) : defaultBudget
    }

    // MARK: - The thread, as the prompt reads it

    static let maximumQuotedMessages = 4
    static let maximumMessageCharacters = 500

    /// Text after the caret as a mail prompt should carry it: the rest of the user's own draft, then
    /// each quoted message as "Sender: what they wrote", newest first. Raw, a quoted thread is mostly
    /// From/To/Cc lines with every address, signatures, phone numbers and footers: 1500 characters of
    /// a typical business thread can hold two sentences of actual message. A base model reads all of
    /// it as the passage it continues, so the noise displaces the words that matter and draws the
    /// completion toward boilerplate. Text with no quote header comes back unchanged.
    static func condensedThread(_ trailingText: String) -> String {
        guard let first = QuotedReplyParser.headerRange(in: trailingText) else { return trailingText }
        var parts: [String] = []
        let ownText = cleanedLines(trailingText[..<first.lowerBound])
        if !ownText.isEmpty { parts.append(ownText) }
        var rest = String(trailingText[first.lowerBound...])
        var previous: QuotedReplyParser.QuotedMessage?
        while parts.count <= maximumQuotedMessages, let header = QuotedReplyParser.headerRange(in: rest) {
            guard let message = QuotedReplyParser.looseMessage(in: String(rest[header.lowerBound...])) else { break }
            // An "-----Original Message-----" rule and the From block under it are two header
            // matches for one message: read it once.
            let isRepeat = message.sender == previous?.sender && message.body == previous?.body
            previous = message
            let body = cleanedLines(Substring(message.body))
            if !isRepeat, !body.isEmpty { parts.append("\(message.sender ?? "They"): \(String(body.prefix(maximumMessageCharacters)))") }
            // Continue after this header line; the next header found is the next, older message.
            rest = String(rest[header.upperBound...])
        }
        return parts.joined(separator: "\n\n")
    }

    /// The message's own lines, ending where its signature starts: at a closing ("Best regards",
    /// "Saygılarımla"), or, once the message has said something (a sentence, not just its greeting),
    /// at the first short line that is not a sentence (a name, "HEAD OF OPERATIONS"). Lines that are
    /// only contact details (an address, a bare link, a phone number) are dropped wherever they
    /// appear; a sentence that mentions a link stays.
    private static func cleanedLines(_ text: Substring) -> String {
        var kept: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Blank lines and rules ("________") carry nothing.
            guard line.contains(where: \.isLetter) else { continue }
            let bare = line.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
            if signOffs.contains(bare) { break }
            if isContactDetail(line) { continue }
            if kept.contains(where: saysSomething), isSignatureLine(line) { break }
            kept.append(line)
        }
        return kept.joined(separator: " ")
    }

    /// A line that ends like a sentence or a salutation, or is a list item: message content.
    private static func isSentence(_ line: String) -> Bool {
        guard let last = line.last else { return false }
        return ".?!:,;؟".contains(last) || ["-", "•", "*"].contains(line.first.map(String.init) ?? "")
    }

    /// A line of actual message: it ends a sentence, is a list item, or is longer than a name or a
    /// title. A greeting ("Hi Alex,") is not: the short line after it is the message, not a signature.
    private static func saysSomething(_ line: String) -> Bool {
        guard let last = line.last else { return false }
        if ".?!؟".contains(last) || ["-", "•", "*"].contains(line.first.map(String.init) ?? "") { return true }
        return !",:".contains(last) && line.split(whereSeparator: \.isWhitespace).count > 4
    }

    /// A name, a title or a label: a few words that do not form a sentence.
    private static func isSignatureLine(_ line: String) -> Bool {
        !isSentence(line) && line.split(whereSeparator: \.isWhitespace).count <= 4
    }

    /// A line that is only contact details: an address, a link or a profile with at most two other
    /// words around it ("example.com | LinkedIn"), or mostly digits (a phone number).
    private static func isContactDetail(_ line: String) -> Bool {
        let words = line.split(whereSeparator: \.isWhitespace)
        let isContactWord = { (word: Substring) -> Bool in
            let lower = word.lowercased()
            return lower.contains("@") || lower.contains("http") || lower.hasPrefix("www.") || lower.contains("linkedin")
        }
        if words.contains(where: isContactWord) {
            let otherWords = words.filter { !isContactWord($0) && $0.contains(where: \.isLetter) }
            if otherWords.count <= 2 { return true }
        }
        let digits = line.filter(\.isNumber).count
        return digits >= 7 && Double(digits) / Double(line.count) > 0.4
    }

    /// Closings after which a message's signature starts (English, Dutch and Turkish).
    private static let signOffs: Set<String> = [
        "best regards", "kind regards", "warm regards", "regards", "best", "cheers", "thanks", "thank you",
        "many thanks", "sincerely", "yours sincerely", "met vriendelijke groet", "groeten",
        "saygılarımla", "saygılar", "iyi çalışmalar", "teşekkürler", "sevgiler"
    ]

    // MARK: - Subject, recipient and window

    /// The subject of the message being replied to, from the quoted header after the caret
    /// ("Subject: Re: Q3 rollout plan"). Nil when the field holds no Outlook-style header (a new
    /// message, or Mail's "On …, X wrote:" quote, whose compose window title already is the subject).
    static func quotedSubject(in trailingText: String, precedingText: String = "") -> String? {
        QuotedReplyParser.quotedSubject(precedingText: precedingText, in: trailingText)
    }

    /// Who the reply is addressed to: the sender of the newest quoted message ("From: Jordan Lee
    /// <jordan@example.com>" → "Jordan Lee"). Nil when there is no quote, the header names no
    /// sender, or the sender is the user (a follow-up to their own mail goes to someone else).
    ///
    /// Why: without it the model saw the user's name everywhere (the quoted message greets them,
    /// their own signature signs with it) and no one else's as the addressee, so "Dear " completed
    /// to the user's own name.
    static func replyRecipient(in trailingText: String, precedingText: String = "", userName: String?) -> String? {
        guard let sender = QuotedReplyParser.quotedMessage(precedingText: precedingText, trailingText: trailingText)?.sender?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            // A bare address is no name to greet, and the model would copy it into the salutation.
            !sender.isEmpty, !sender.contains("@")
        else { return nil }
        if let userName, names(sender, as: userName) { return nil }
        return sender
    }

    /// True when every word of `userName` appears in `sender`, ignoring case and diacritics, so
    /// "Alex" and "Alex Morgan" both match a header that says "Alex Morgan".
    private static func names(_ sender: String, as userName: String) -> Bool {
        let words: (String) -> Set<String> = { text in
            Set(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .split(whereSeparator: { !$0.isLetter }).map(String.init))
        }
        let userWords = words(userName)
        return !userWords.isEmpty && userWords.isSubset(of: words(sender))
    }

    /// Outlook titles its main window after the open folder ("Inbox • All Accounts", "Sent Items •
    /// alex@example.com"). An inline reply there has no window of its own, so that title names a
    /// mailbox, not a conversation, and must not be matched against conversation titles.
    static func isMailboxWindowTitle(_ title: String, bundleIdentifier: String?) -> Bool {
        bundleIdentifier?.lowercased() == "com.microsoft.outlook" && title.contains(" • ")
    }
}
