import Foundation

/// File overview:
/// Reads one decompressed record of New Outlook's local mail store (`HxStore.hxd`) as a mail message.
///
/// New Outlook for Mac keeps the mail it syncs in an undocumented store. What is known, from reading
/// this Mac's store (there is no published format):
/// - The file is mostly LZ4-compressed records, each behind a 20-byte header (see `HxStoreFile`).
/// - A mail record carries its message class (`IPM.Note`, UTF-16) and its string properties as
///   consecutive null-terminated UTF-16 strings: sender address and name, the internet message id
///   (`<…@…>`), a preview of the body, the subject (`Re: …`) and the thread topic (the subject
///   without its reply prefixes). Records with a body hold its HTML, the strings follow it.
/// - Times are .NET ticks (100 ns since 0001-01-01), little-endian, in the record's leading binary
///   part; the earliest plausible one is when the message was sent.
/// - Records are versioned: the same message appears several times; `HxStoreFile` keeps the
///   fullest version per message id.
///
/// Because the layout is inferred, every field is read defensively and classified by shape rather
/// than position: a record that does not look like a mail message yields nil, never a guess.
nonisolated struct HxMailRecord: Equatable, Sendable {
    let messageID: String
    let messageClass: String
    let subject: String?
    let senderAddress: String?
    let senderName: String?
    let preview: String?
    /// The body as stored (HTML), straight from the parser.
    var bodyHTML: String?
    /// The body as text, set by `HxStoreFile` (which drops the HTML to keep memory small).
    var bodyText: String?
    let sent: Date?

    /// The thread's title: the subject without reply and forward prefixes.
    var topic: String? {
        subject.map { HxStoreRecordParser.strippingPrefixes($0) }
    }
}

nonisolated enum HxStoreRecordParser {
    static let earliest = Date(timeIntervalSince1970: 1_420_070_400)  // 2015-01-01
    /// Where a record's class and string table are looked for: its first bytes, and the bytes after
    /// its HTML body.
    static let headWindow = 48 * 1024
    static let tailWindow = 16 * 1024
    /// .NET ticks at the Unix epoch.
    static let unixEpochTicks: UInt64 = 621_355_968_000_000_000

    static func parse(_ bytes: [UInt8], now: Date = Date()) -> HxMailRecord? {
        // The message class sits in the record's leading part (about 2 KB in, just before a body);
        // looking only there keeps non-mail records, most of the store, cheap to reject.
        let head = min(bytes.count, headWindow)
        guard let classOffset = find(Array("IPM.".utf16LittleEndianBytes), in: bytes, until: head) else { return nil }
        let htmlStart = find(Array("<html".utf8), in: bytes, until: head)
        let htmlEnd = htmlStart.flatMap { start in findLast(Array("</html>".utf8), in: bytes, after: start).map { $0 + 7 } }

        // String properties live outside the HTML body, in a few kilobytes before it or after it.
        var segments: [ArraySlice<UInt8>] = []
        if let htmlStart, let htmlEnd {
            segments = [bytes[..<htmlStart], bytes[htmlEnd..<min(bytes.count, htmlEnd + tailWindow)]]
        } else {
            segments = [bytes[..<head]]
        }
        let strings = segments.flatMap(orderedStrings)

        guard let messageClass = strings.first(where: { $0.hasPrefix("IPM.") }), isRemembered(messageClass),
              let messageID = strings.first(where: isMessageID) else { return nil }
        let senderIndex = strings.firstIndex(where: isAddress)
        let senderAddress = senderIndex.map { strings[$0].lowercased() }
        let senderName = senderIndex.flatMap { index -> String? in
            guard index + 1 < strings.count else { return nil }
            let next = strings[index + 1]
            return isName(next) ? next : nil
        }

        let texts = strings.filter { !isAddress($0) && !isMessageID($0) && !$0.hasPrefix("IPM.") && containsLetter($0) }
        // Subject candidates are short; each one's topic is computed once.
        let shortTexts = texts.filter { $0.count <= 300 }
        let topicKeys = shortTexts.map { strippingPrefixes($0).lowercased() }
        let topicCounts = Dictionary(topicKeys.map { ($0, 1) }, uniquingKeysWith: +)
        let subject = shortTexts.first(where: hasReplyPrefix)
            ?? zip(shortTexts, topicKeys).first { (topicCounts[$0.1] ?? 0) >= 2 }?.0
        let preview = texts
            .filter { $0.count >= 20 && $0 != subject && $0 != subject.map(strippingPrefixes) && $0 != senderName }
            .max { $0.count < $1.count }

        let body = htmlStart.flatMap { start in htmlEnd.map { String(lossyUTF8: bytes[start..<$0]) } }
        let leading = min(htmlStart ?? bytes.count, classOffset, 4096)
        return HxMailRecord(
            messageID: messageID, messageClass: messageClass, subject: subject, senderAddress: senderAddress,
            senderName: senderName, preview: preview, bodyHTML: body, sent: sentDate(in: bytes, before: leading, now: now)
        )
    }

    /// The earliest .NET-ticks value in the record's leading binary part that is a plausible mail
    /// time (2015 to a day from now).
    static func sentDate(in bytes: [UInt8], before limit: Int, now: Date) -> Date? {
        let low = ticks(for: earliest), high = ticks(for: now.addingTimeInterval(86_400))
        var best: UInt64?
        var offset = 0
        while offset + 8 <= limit {
            var value: UInt64 = 0
            for index in 0..<8 { value |= UInt64(bytes[offset + index]) << (8 * UInt64(index)) }
            if value > low, value < high, value < (best ?? .max) { best = value }
            offset += 1
        }
        return best.map { Date(timeIntervalSince1970: Double($0 - unixEpochTicks) / 10_000_000) }
    }

    static func ticks(for date: Date) -> UInt64 {
        UInt64(date.timeIntervalSince1970 * 10_000_000) + unixEpochTicks
    }

    /// The null-terminated UTF-16 strings of a segment, in order, read at whichever byte alignment
    /// yields more text (records do not keep strings at a fixed alignment).
    static func orderedStrings(_ segment: ArraySlice<UInt8>) -> [String] {
        var best: [String] = []
        var bestLength = 0
        for parity in 0..<2 {
            var strings: [String] = []
            var units: [UInt16] = []
            var index = segment.startIndex + parity
            func flush() {
                if units.count >= 2, units.count <= 2000 {
                    // Unpaired surrogates become U+FFFD, which `isPrintable` rejects.
                    let text = String(decoding: units, as: UTF16.self)
                    if isPrintable(text) { strings.append(text) }
                }
                units.removeAll(keepingCapacity: true)
            }
            while index + 1 < segment.endIndex {
                let unit = UInt16(segment[index]) | UInt16(segment[index + 1]) << 8
                if unit == 0 { flush() } else { units.append(unit) }
                index += 2
            }
            flush()
            let length = strings.reduce(0) { $0 + $1.count }
            if length > bestLength {
                best = strings
                bestLength = length
            }
        }
        return best
    }

    // MARK: - Classification

    // Classification runs on every string of every record in the store, so it uses plain character
    // checks rather than regular expressions (which go through NSString and dominate the scan).

    /// `local@domain.tld`: one @, an allowed local part, a dotted domain with a letters-only TLD.
    /// Mail, and meeting invitations and cancellations (their text carries the agenda). Replies to
    /// invitations ("Accepted: …") say nothing else and are left out, as are other item classes.
    static func isRemembered(_ messageClass: String) -> Bool {
        messageClass.hasPrefix("IPM.Note") || messageClass.hasPrefix("IPM.Schedule.Meeting.Request")
            || messageClass.hasPrefix("IPM.Schedule.Meeting.Canceled")
    }

    static func isAddress(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].count >= 4 else { return false }
        let localAllowed: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber || "._%+'-".contains($0)) }
        let domainAllowed: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber || ".-".contains($0)) }
        guard parts[0].allSatisfy(localAllowed), parts[1].allSatisfy(domainAllowed),
              let dot = parts[1].lastIndex(of: "."), dot != parts[1].startIndex else { return false }
        let tld = parts[1][parts[1].index(after: dot)...]
        return tld.count >= 2 && tld.allSatisfy(\.isLetter)
    }

    /// `<id@host>`: angle brackets around one token containing an @.
    static func isMessageID(_ text: String) -> Bool {
        guard text.count >= 5, text.first == "<", text.last == ">" else { return false }
        let inner = text.dropFirst().dropLast()
        return inner.contains("@") && !inner.contains { $0 == "<" || $0 == ">" || $0.isWhitespace }
    }

    static func hasReplyPrefix(_ text: String) -> Bool {
        replyPrefixLength(text) > 0
    }

    static func strippingPrefixes(_ text: String) -> String {
        String(text.dropFirst(replyPrefixLength(text))).trimmingCharacters(in: .whitespaces)
    }

    private static let replyPrefixes: Set<String> = ["re", "fw", "fwd", "aw", "wg", "sv", "ynt", "ilt", "tr"]

    /// Characters taken by leading "Re:", "FW:", "AW [2]:" … prefixes, repeated.
    private static func replyPrefixLength(_ text: String) -> Int {
        // Fast path: every prefix starts with one of these letters; most strings start otherwise.
        guard let first = text.first, "rRfFaAwWsSyYiItT".contains(first) else { return 0 }
        let characters = Array(text.prefix(64))
        var index = 0
        var consumed = 0
        while true {
            var cursor = skipSpaces(characters, from: index)
            let wordStart = cursor
            while cursor < characters.count, characters[cursor].isLetter, cursor - wordStart < 4 { cursor += 1 }
            guard replyPrefixes.contains(String(characters[wordStart..<cursor]).lowercased()) else { return consumed }
            cursor = skipSpaces(characters, from: cursor)
            if cursor < characters.count, characters[cursor] == "[" {
                while cursor < characters.count, characters[cursor] != "]" { cursor += 1 }
                cursor = skipSpaces(characters, from: cursor + 1)
            }
            guard cursor < characters.count, characters[cursor] == ":" else { return consumed }
            cursor = skipSpaces(characters, from: cursor + 1)
            index = cursor
            consumed = cursor
        }
    }

    private static func skipSpaces(_ characters: [Character], from start: Int) -> Int {
        var cursor = start
        while cursor < characters.count, characters[cursor] == " " { cursor += 1 }
        return cursor
    }

    private static func isName(_ text: String) -> Bool {
        text.count <= 80 && !text.contains("@") && !text.hasPrefix("IPM.") && containsLetter(text)
    }

    private static func containsLetter(_ text: String) -> Bool {
        text.contains { $0.isLetter }
    }

    /// Mostly printable, no replacement characters: real text rather than binary read as UTF-16.
    /// Binary data read as UTF-16 lands mostly in CJK and private-use planes; real strings here are
    /// overwhelmingly Latin, so a run dominated by ideographs is treated as binary. One pass.
    private static func isPrintable(_ text: String) -> Bool {
        var total = 0, unprintable = 0, ideographs = 0
        for scalar in text.unicodeScalars {
            total += 1
            let value = scalar.value
            if value == 0xFFFD { return false }
            switch value {
            case 0..<0x20, 0x7F...0x9F, 0xE000...0xF8FF: unprintable += 1
            case 0x3400...0x9FFF, 0xAC00...0xD7AF: ideographs += 1
            default: break
            }
        }
        return unprintable * 100 <= total * 5 && ideographs * 2 < total
    }

    // MARK: - Byte search

    static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int = 0, until limit: Int? = nil) -> Int? {
        let end = min(limit ?? haystack.count, haystack.count)
        guard !needle.isEmpty, end >= needle.count else { return nil }
        var index = start
        while index <= end - needle.count {
            if haystack[index] == needle[0], haystack[index..<(index + needle.count)].elementsEqual(needle) { return index }
            index += 1
        }
        return nil
    }

    static func findLast(_ needle: [UInt8], in haystack: [UInt8], after start: Int) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        var index = haystack.count - needle.count
        while index > start {
            if haystack[index] == needle[0], haystack[index..<(index + needle.count)].elementsEqual(needle) { return index }
            index -= 1
        }
        return nil
    }
}

nonisolated private extension String {
    var utf16LittleEndianBytes: [UInt8] {
        utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    }
}
