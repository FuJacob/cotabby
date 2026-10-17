import Foundation

/// File overview:
/// The text rules every message passes on its way into conversation memory, and the keys memory
/// matches conversations and people by.
///
/// Why pure and in one place: these decide what is stored (secrets removed, quoted mail dropped)
/// and which conversation a window belongs to, so they are deterministic functions pinned by
/// tests. The keys are part of the stored data (HMAC tags of these normalized forms), so changing a
/// rule means re-syncing what is already stored.

/// How a conversation title is matched: case- and space-insensitively, without bidi marks, a
/// leading unread badge ("(3) ") or mail reply prefixes, so "Re: POC results" and "POC results" are
/// one thread's title.
nonisolated enum ConversationTitleKey {
    static func key(_ title: String) -> String {
        var cleaned = title.replacingOccurrences(
            of: "[\u{200E}\u{200F}\u{202A}-\u{202E}\u{2066}-\u{2069}]", with: "", options: .regularExpression
        )
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^\(\d+\+?\)\s*"#, with: "", options: .regularExpression)
        // Reply and forward prefixes (English, German, Nordic, Turkish), repeated: "Re: Fwd: x".
        var previous = ""
        while previous != cleaned {
            previous = cleaned
            cleaned = cleaned.replacingOccurrences(
                of: #"^(re|fw|fwd|aw|wg|sv|ynt|ilt|tr)\s*(\[\d+\])?\s*:\s*"#, with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return cleaned.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// People are compared case-insensitively with surrounding space and mail brackets dropped, so
/// "Ayşe Yılmaz <ayse@example.com>" in one source and "ayse@example.com" in another are the same person.
nonisolated enum ParticipantNormalizer {
    static func normalize(_ name: String) -> String {
        var cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleaned.hasSuffix(">"), let open = cleaned.range(of: "<", options: .backwards) {
            cleaned = String(cleaned[open.upperBound..<cleaned.index(before: cleaned.endIndex)])
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A mail conversation: one thread with one audience. Mail clients join threads by References,
/// In-Reply-To and subject, which any sender controls, so the thread id alone could put a stranger,
/// or a reply with someone new on it, into a conversation whose history they never saw. Each set of
/// people (the user left out) within a thread is a conversation of its own, and memory's "exactly
/// the same people" rules then hold by construction.
nonisolated enum MailAudience {
    static func conversationID(thread: String, people: Set<String>) -> String {
        thread + "|" + people.map(ParticipantNormalizer.normalize).sorted().joined(separator: ",")
    }
}

/// Removes secrets and boilerplate before a message is stored: anything stored can surface in a
/// suggestion, so one-time codes, card numbers, IBANs, credentials and API keys never reach it.
/// Lossy on purpose; when in doubt, text is removed.
nonisolated enum MemoryTextScrubber {
    static let redacted = "[redacted]"

    private static let secretPatterns: [NSRegularExpression] = [
        // Card numbers: 13-19 digits, optionally grouped by spaces or dashes.
        #"\b(?:\d[ -]?){13,19}\b"#,
        // IBAN.
        #"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){3,7}(?:[ ]?[A-Z0-9]{1,3})?\b"#,
        // API keys and tokens: well-known prefixes, and long runs of key-like characters.
        #"\b(?:sk|pk|rk|ghp|gho|xox[abpr]|AKIA|AIza)[-_A-Za-z0-9]{12,}\b"#,
        #"\b[A-Za-z0-9_\-]{32,}\b"#,
        // "password: x", "şifre: x", "pin 1234": the value after the label goes.
        #"(?i)\b(password|passwd|pwd|parola|şifre|sifre|pin|passcode|token|secret)\b\s*[:=]?\s*\S+"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// A message that is mainly a one-time code ("Your code is 482913", "Doğrulama kodu: 4829").
    private static let oneTimeCode = try? NSRegularExpression(
        pattern: #"(?i)\b(code|kod|kodu|otp|verification|doğrulama|dogrulama|one[- ]time)\b.{0,40}\b\d{4,8}\b"#
    )

    static func isOneTimeCode(_ text: String) -> Bool {
        guard let oneTimeCode else { return false }
        return oneTimeCode.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The text with secrets redacted and whitespace collapsed, or nil when nothing worth
    /// remembering is left (empty, or the whole message is a one-time code).
    static func scrub(_ text: String) -> String? {
        guard !text.isEmpty, !isOneTimeCode(text) else { return nil }
        var cleaned = text
        for pattern in secretPatterns {
            cleaned = pattern.stringByReplacingMatches(
                in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: redacted
            )
        }
        cleaned = cleaned.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == redacted ? nil : cleaned
    }
}

/// Keeps only what a mail added: everything before the first quote header ("On … wrote:",
/// "… tarihinde … yazdı:", an "Original Message" rule, a "From:" block) or signature delimiter,
/// without `>`-quoted lines, so a thread does not store the same paragraph once per reply.
nonisolated enum MailQuoteStripper {
    private static let quoteHeader = try? NSRegularExpression(
        pattern: #"(?im)^(on .{5,200} wrote:|.{0,200} tarihinde .{0,100} yazdı:|-{2,} ?original message ?-{2,}|from: .+)$"#
    )
    private static let signature = try? NSRegularExpression(
        pattern: #"(?im)^(-- ?|—\s*|sent from my .+|iphone'umdan gönderildi.*)$"#
    )

    static func strip(_ text: String) -> String {
        let whole = NSRange(text.startIndex..., in: text)
        var cut = text.endIndex
        for pattern in [quoteHeader, signature].compactMap({ $0 }) {
            if let match = pattern.firstMatch(in: text, range: whole), let range = Range(match.range, in: text) {
                cut = min(cut, range.lowerBound)
            }
        }
        return text[..<cut]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix(">") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Splits a message into the passages that are embedded: windows of `size` words overlapping by
/// `overlap`. Chat messages are almost always one passage; long mails become several, each small
/// enough for the embedding model's context.
nonisolated enum PassageChunker {
    static let defaultSize = 256
    static let defaultOverlap = 32

    static func chunks(_ text: String, size: Int = defaultSize, overlap: Int = defaultOverlap) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > size else { return [text] }
        let step = max(1, size - min(overlap, size - 1))
        return stride(from: 0, to: words.count, by: step).map { start in
            words[start..<min(start + size, words.count)].joined(separator: " ")
        }
    }

    /// What is embedded for a message: the date and speaker give the model context
    /// ("[2026-09-12] Ayşe: the invoice is paid"), and a mail subject anchors short replies.
    static func passageText(timestamp: Date, sender: String, isFromMe: Bool, subject: String?, text: String) -> String {
        let speaker = isFromMe ? "You" : (sender.isEmpty ? "Someone" : sender)
        let regarding = subject.map { " (re: \($0))" } ?? ""
        return "[\(dayFormatter.string(from: timestamp))] \(speaker)\(regarding): \(text)"
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// Words for keyword search: Unicode word characters, lowercased, longer than one character.
nonisolated enum MemoryTerms {
    private static let word = try? NSRegularExpression(pattern: #"\w+"#)

    static func terms(_ text: String) -> [String] {
        guard let word else { return [] }
        let lowered = text.lowercased()
        return word.matches(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)).compactMap { match in
            guard let range = Range(match.range, in: lowered) else { return nil }
            let term = String(lowered[range])
            return term.count > 1 ? term : nil
        }
    }
}

/// BM25-style ranking of a small, already-scoped set of documents (one conversation's recent
/// messages). Terms also match as word prefixes, so a word being typed ("invo") finds "invoice".
nonisolated enum KeywordScorer {
    /// Indices of `documents` that match `query`, best first, at most `limit`.
    static func rank(query: String, documents: [String], limit: Int) -> [Int] {
        let queryTerms = Set(MemoryTerms.terms(query))
        guard !queryTerms.isEmpty, !documents.isEmpty, limit > 0 else { return [] }
        let tokenized = documents.map(MemoryTerms.terms)
        let averageLength = max(Double(tokenized.reduce(0) { $0 + $1.count }) / Double(tokenized.count), 1)

        func matches(_ term: String, _ tokens: [String]) -> Int {
            tokens.reduce(0) { $0 + (($1 == term || (term.count >= 3 && $1.hasPrefix(term))) ? 1 : 0) }
        }

        let documentFrequency = Dictionary(uniqueKeysWithValues: queryTerms.map { term in
            (term, tokenized.reduce(0) { $0 + (matches(term, $1) > 0 ? 1 : 0) })
        })
        let count = Double(documents.count)
        var scored: [(score: Double, index: Int)] = []
        for (index, tokens) in tokenized.enumerated() {
            var score = 0.0
            for term in queryTerms {
                let frequency = Double(matches(term, tokens))
                guard frequency > 0 else { continue }
                let df = Double(documentFrequency[term] ?? 0)
                let idf: Double = Foundation.log(1 + (count - df + 0.5) / (df + 0.5))
                score += idf * frequency * 2.2 / (frequency + 1.2 * (0.25 + 0.75 * Double(tokens.count) / averageLength))
            }
            if score > 0 { scored.append((score, index)) }
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .prefix(limit).map(\.index)
    }
}

/// Weighted reciprocal rank fusion of a vector ranking and a keyword ranking: robust to their
/// incomparable score scales. `vectorWeight` 1 is pure vector, 0 pure keyword. `rankOffset` is
/// RRF's usual k = 60, which damps the gap between the top few ranks.
nonisolated enum ReciprocalRankFusion {
    static func fuse(vector: [String], keyword: [String], vectorWeight: Double, rankOffset: Double = 60)
        -> [(id: String, score: Double)] {
        var scores: [String: Double] = [:]
        for (rank, id) in vector.enumerated() { scores[id, default: 0] += vectorWeight / (rankOffset + Double(rank) + 1) }
        for (rank, id) in keyword.enumerated() { scores[id, default: 0] += (1 - vectorWeight) / (rankOffset + Double(rank) + 1) }
        return scores.map { (id: $0.key, score: $0.value) }.sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
    }
}

nonisolated extension String {
    /// Text from bytes that should be UTF-8, with any invalid sequence replaced by U+FFFD rather
    /// than failing: the readers decode other apps' stores, and one stray byte in a message must
    /// cost a character, not the whole message (the failable `String(bytes:encoding:)` would).
    init<Bytes: Collection>(lossyUTF8 bytes: Bytes) where Bytes.Element == UInt8 {
        self.init(decoding: bytes, as: UTF8.self)
    }
}
