import Foundation

/// File overview:
/// Decides which of the Teams cache's rows become memory messages, and with which conversation,
/// title, sender and participants.
///
/// Why pure and separate from the cache reader: these rules decide which messages a suggestion in
/// a given chat may see, so they are pinned by tests with small dictionary fixtures shaped like
/// Teams' IndexedDB values, without a LevelDB. They were first prototyped in Python on top of
/// CCL Forensics' `ccl_chromium_reader`, which is why some helpers name the Python behaviour they
/// keep (string stripping, code-point sorting, dict order): the tie-breaks depend on it.
///
/// Inputs, as `TeamsCacheReader` decodes them (plain Foundation values: dictionaries, arrays,
/// strings, numbers): the rows of `conversations` (`id`, `threadProperties.topic`, `members[].id`), the
/// messages of every reply chain's `messageMap` (`id`, `conversationId`, `creator`,
/// `imDisplayName`, `fromDisplayNameInToken`, `content`, `messageType`, `originalArrivalTime`,
/// `clientArrivalTime`, `deletionInfo`), and display names by member id from `profiles`.
///
/// The rules:
/// - Who "me" is: the member present in the most conversations (no account id needed); a tie goes
///   to the most frequent sender among the tied, since the user writes in every chat they keep.
/// - Kept: messages people wrote (`RichText/Html`, `Text`, `RichText`) that are not deleted and are
///   not in Teams' own feeds (`48:` conversations); their HTML becomes text (`TeamsMessageHTML`).
/// - Title: the conversation's topic; else, for a 1:1 chat, the other person, whose id is part of
///   the conversation id (`19:<guid>_<guid>@unq.gbl.spaces`); else the members' names. Teams' own
///   cached `chatTitle` is never used: it is computed from whichever avatars were loaded and names a
///   group after one person, which would let a group pass for a 1:1.
/// - Participants: the cached members, the two ids of a 1:1 and everyone who wrote, minus the
///   user. Only a 1:1's audience is certain; every other conversation also gets
///   `teams-group:<conversationId>`, so a group where only Avery wrote never equals the 1:1 with Avery
///   and the two never share memory.
/// - Names: a person's directory profile, else the name most of their messages carry (a message
///   sent on someone's behalf carries the other name).
/// - Ids: `<conversationId>/<message id>`; time: the original arrival time in milliseconds.
nonisolated enum TeamsMessageMapper {
    static let groupMarker = "teams-group:"
    static let textTypes: Set<String> = ["richtext/html", "text", "richtext"]
    static let systemConversationPrefixes = ["48:"]

    struct Message: Equatable {
        let sourceMessageID: String
        let conversationID: String
        let conversationTitle: String
        let sender: String
        let isFromMe: Bool
        let arrivalMilliseconds: Double
        let text: String
        let participants: [String]

        var timestamp: Date { Date(timeIntervalSince1970: arrivalMilliseconds / 1000) }
    }

    struct Result: Equatable {
        let messages: [Message]
        /// The newest arrival time seen (at least `afterMilliseconds`): the next cursor.
        let newestMilliseconds: Double
    }

    struct Conversation: Equatable {
        let id: String
        let topic: String
        let members: [String]
    }

    /// Maps the cached rows to messages that arrived after `afterMilliseconds`, in input order.
    /// Messages "arriving" later than a day from now are not trusted (clock skew allowance).
    static var latestAcceptedMilliseconds: Double { Date().timeIntervalSince1970 * 1000 + 86_400_000 }

    static func map(
        conversations rawConversations: [[String: Any]],
        messages: [[String: Any]],
        profiles: [String: String],
        afterMilliseconds: Double
    ) -> Result {
        // Conversation rows by id; a later row for the same id replaces the earlier one but keeps
        // its position (a Python dict).
        var chatOrder: [String] = []
        var chats: [String: Conversation] = [:]
        for raw in rawConversations {
            guard let chat = conversation(raw) else { continue }
            if chats.updateValue(chat, forKey: chat.id) == nil { chatOrder.append(chat.id) }
        }
        let me = self.me(chats: chatOrder.compactMap { chats[$0] }, messages: messages)
        let names = namesByMRI(messages: messages, profiles: profiles)

        var writers: [String: Set<String>] = [:]
        for message in messages {
            let creator = mri(text(message["creator"]))
            if !creator.isEmpty { writers[text(message["conversationId"]), default: []].insert(creator) }
        }

        var participantsCache: [String: [String]] = [:]
        func participants(of conversationID: String) -> [String] {
            if let cached = participantsCache[conversationID] { return cached }
            var people = Set(chats[conversationID]?.members ?? [])
            let oneToOne = oneToOneMembers(conversationID)
            people.formUnion(oneToOne)
            people.formUnion(writers[conversationID] ?? [])
            if oneToOne.isEmpty { people.insert(groupMarker + conversationID) }
            let result = pythonSorted(people.filter { !$0.isEmpty && $0 != me })
            participantsCache[conversationID] = result
            return result
        }

        var titles: [String: String] = [:]
        func title(of conversationID: String, participants: [String]) -> String {
            if let cached = titles[conversationID] { return cached }
            let result: String
            if let topic = chats[conversationID]?.topic, !topic.isEmpty {
                result = topic
            } else {
                result = pythonSorted(participants.compactMap { names[$0] }).joined(separator: ", ")
            }
            titles[conversationID] = result
            return result
        }

        var mapped: [Message] = []
        var newest = afterMilliseconds
        for message in messages {
            let conversationID = text(message["conversationId"])
            // No time, or one from the future: a message from the future must never become the
            // cursor, or every real message after it would be skipped.
            guard isWrittenByPeople(message, conversationID: conversationID),
                  let arrived = trustedArrival(message) else { continue }
            newest = max(newest, arrived)
            guard arrived > afterMilliseconds else { continue }
            let body = TeamsMessageHTML.text(text(message["content"]))
            guard !body.isEmpty else { continue }
            let creator = mri(text(message["creator"]))
            let people = participants(of: conversationID)
            let sender = senderName(message, creator: creator, names: names)
            let messageID = text(message["id"])
            mapped.append(Message(
                sourceMessageID: "\(conversationID)/\(messageID.isEmpty ? String(Int64(arrived)) : messageID)",
                conversationID: conversationID,
                conversationTitle: title(of: conversationID, participants: people),
                sender: sender,
                isFromMe: !me.isEmpty && creator == me,
                arrivalMilliseconds: arrived,
                text: body,
                participants: people
            ))
        }
        return Result(messages: mapped, newestMilliseconds: newest)
    }

    // MARK: - Rules

    /// A message a person wrote in a real conversation: not in Teams' own feeds, of a text type, and
    /// not deleted.
    static func isWrittenByPeople(_ message: [String: Any], conversationID: String) -> Bool {
        !conversationID.isEmpty
            && !systemConversationPrefixes.contains(where: { conversationID.hasPrefix($0) })
            && textTypes.contains(text(message["messageType"]).lowercased())
            && !isTruthy(message["deletionInfo"])
    }

    /// The message's arrival time, or nil when it has none or one beyond `latestAcceptedMilliseconds`.
    static func trustedArrival(_ message: [String: Any]) -> Double? {
        guard let arrived = milliseconds(message["originalArrivalTime"]) ?? milliseconds(message["clientArrivalTime"]),
              arrived <= latestAcceptedMilliseconds else { return nil }
        return arrived
    }

    /// The sender's profile name, else the names the message itself carries.
    static func senderName(_ message: [String: Any], creator: String, names: [String: String]) -> String {
        var sender = names[creator] ?? ""
        if sender.isEmpty { sender = PythonText.strip(text(message["imDisplayName"])) }
        if sender.isEmpty { sender = PythonText.strip(text(message["fromDisplayNameInToken"])) }
        return sender
    }

    /// `8:orgid:<guid>` of both people of a 1:1 chat id, lowercased; empty for any other id.
    static func oneToOneMembers(_ conversationID: String) -> [String] {
        let prefix = "19:"
        let suffix = "@unq.gbl.spaces"
        guard conversationID.hasPrefix(prefix), conversationID.hasSuffix(suffix) else { return [] }
        let middle = Array(conversationID.unicodeScalars.dropFirst(prefix.count).dropLast(suffix.count))
        // `([0-9a-fA-F-]{36})_([0-9a-fA-F-]{36})`: the underscore cannot be part of a guid, so the
        // split is fixed.
        guard middle.count == 73, middle[36] == "_" else { return [] }
        let isGUIDCharacter: (Unicode.Scalar) -> Bool = { (scalar: Unicode.Scalar) -> Bool in
            switch scalar {
            case "0"..."9", "a"..."f", "A"..."F", "-": return true
            default: return false
            }
        }
        let first = middle[0..<36]
        let second = middle[37...]
        guard first.allSatisfy(isGUIDCharacter), second.allSatisfy(isGUIDCharacter) else { return [] }
        return [first, second].map { "8:orgid:" + String(String.UnicodeScalarView($0)).lowercased() }
    }

    static func conversation(_ raw: [String: Any]) -> Conversation? {
        let id = text(raw["id"])
        guard !id.isEmpty else { return nil }
        let properties = raw["threadProperties"] as? [String: Any] ?? [:]
        let members = raw["members"] as? [Any] ?? []
        var memberIDs = Set<String>()
        for case let member as [String: Any] in members where isTruthy(member["id"]) {
            memberIDs.insert(mri(text(member["id"])))
        }
        return Conversation(id: id, topic: PythonText.strip(text(properties["topic"])), members: pythonSorted(memberIDs))
    }

    /// The signed-in user of one profile's cache: the member of the most conversations (the user
    /// is in every one of their chats). When several people tie (a cache whose chats are all with
    /// one person), the cache cannot say which is the user, and nobody is: guessing by who wrote
    /// more would label the other person's messages "You" and title the chat after the user.
    static func me(chats: [Conversation], messages: [[String: Any]]) -> String {
        var counts = OrderedCounter()
        for chat in chats { counts.add(chat.members) }
        for message in messages { counts.add(oneToOneMembers(text(message["conversationId"]))) }
        guard let top = counts.highestCount else { return "" }
        let best = counts.keys.filter { counts[$0] == top }
        return best.count == 1 ? best[0] : ""
    }

    /// A display name per person: the profile's, else the most common name on their messages
    /// (the first seen of the most common, on a tie).
    static func namesByMRI(messages: [[String: Any]], profiles: [String: String]) -> [String: String] {
        var seen: [String: OrderedCounter] = [:]
        for message in messages {
            let creator = mri(text(message["creator"]))
            let name = PythonText.strip(text(message["imDisplayName"]))
            if !creator.isEmpty, !name.isEmpty { seen[creator, default: OrderedCounter()].add([name]) }
        }
        var names: [String: String] = [:]
        for (person, counter) in seen {
            if let top = counter.highestCount, let name = counter.keys.first(where: { counter[$0] == top }) {
                names[person] = name
            }
        }
        for (person, name) in profiles where !name.isEmpty { names[person] = name }
        return names
    }

    /// Senders appear both as `8:orgid:<guid>` and as a contacts URL ending in it.
    static func mri(_ value: String) -> String {
        let last = value.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? value
        return PythonText.strip(last)
    }

    /// Epoch milliseconds from a number (seconds when below 1e11) or a numeric or ISO 8601 string.
    /// Arrival times outside 2000-01-01 ... 2100-01-01 are not real Teams times. Rejecting them
    /// keeps a corrupt or crafted cache value from trapping a conversion (infinity, NaN, beyond
    /// Int64) or from moving the sync cursor somewhere real messages can never reach again.
    static let earliestMilliseconds = 946_684_800_000.0
    static let latestMilliseconds = 4_102_444_800_000.0

    static func milliseconds(_ value: Any?) -> Double? {
        if let number = number(value) {
            guard number.isFinite, number > 0 else { return nil }
            let milliseconds = number > 1e11 ? number : number * 1000
            return (earliestMilliseconds...latestMilliseconds).contains(milliseconds) ? milliseconds : nil
        }
        guard let string = value as? String else { return nil }
        let stripped = PythonText.strip(string)
        guard !stripped.isEmpty else { return nil }
        if isDecimal(stripped), let number = Double(stripped) { return milliseconds(number) }
        return ISO8601Time.milliseconds(stripped.replacingOccurrences(of: "Z", with: "+00:00"))
            .flatMap { (earliestMilliseconds...latestMilliseconds).contains($0) ? $0 : nil }
    }

    // MARK: - Python value semantics

    /// A string value, or "" for anything else (Python's `_text`).
    static func text(_ value: Any?) -> String {
        value as? String ?? ""
    }

    /// Numbers only: Swift's `Bool` (and `NSNull`, `Date`, strings) are not numbers here, as in
    /// Python `bool` is excluded explicitly.
    static func number(_ value: Any?) -> Double? {
        guard let value else { return nil }
        switch value {
        case is Bool: return nil
        case let double as Double: return double
        case let float as Float: return Double(float)
        case let int as Int: return Double(int)
        case let int as Int64: return Double(int)
        case let int as Int32: return Double(int)
        case let int as UInt64: return Double(int)
        default: return nil
        }
    }

    /// Python truthiness for decoded values.
    static func isTruthy(_ value: Any?) -> Bool {
        guard let value else { return false }
        switch value {
        case is NSNull: return false
        case let bool as Bool: return bool
        case let string as String: return !string.isEmpty
        case let array as [Any]: return !array.isEmpty
        case let dictionary as [String: Any]: return !dictionary.isEmpty
        default:
            if let number = number(value) { return number != 0 }
            return true
        }
    }

    private static func isDecimal(_ text: String) -> Bool {
        // `\d+(\.\d+)?`
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy { ("0"..."9").contains($0) } }
    }

    /// Python sorts strings by code point; Swift's `<` compares canonical equivalents.
    static func pythonSorted<S: Sequence>(_ strings: S) -> [String] where S.Element == String {
        strings.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
    }
}

/// Python's `collections.Counter` where order matters: counts plus first-seen order, so "the most
/// common, first counted on a tie" is what `most_common` returns.
nonisolated struct OrderedCounter {
    private(set) var keys: [String] = []
    private var counts: [String: Int] = [:]

    subscript(key: String) -> Int { counts[key, default: 0] }

    var highestCount: Int? { counts.values.max() }

    mutating func add(_ items: [String]) {
        for item in items {
            if counts[item] == nil { keys.append(item) }
            counts[item, default: 0] += 1
        }
    }
}

/// The subset of Python's `datetime.fromisoformat` Teams times could use:
/// `YYYY-MM-DD[Thh:mm[:ss[.ffffff]]][±hh:mm]`, with any single character as the date/time
/// separator. Without an offset the time is local, as a naive Python datetime's `timestamp()` is.
nonisolated enum ISO8601Time {
    static func milliseconds(_ text: String) -> Double? {
        var scanner = Scanner(scalars: Array(text.unicodeScalars))
        guard let year = scanner.digits(4), scanner.expect("-"), let month = scanner.digits(2), scanner.expect("-"),
              let day = scanner.digits(2) else { return nil }
        var components = DateComponents(year: year, month: month, day: day, hour: 0, minute: 0, second: 0)
        var fraction = 0.0
        var offsetSeconds: Int?
        if !scanner.isAtEnd {
            scanner.index += 1 // the separator
            guard let seconds = scanner.time(into: &components) else { return nil }
            fraction = seconds
            if !scanner.isAtEnd {
                guard let offset = scanner.offsetSeconds() else { return nil }
                offsetSeconds = offset
            }
        }
        guard scanner.isAtEnd else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = offsetSeconds.flatMap { TimeZone(secondsFromGMT: $0) } ?? .current
        // A date that does not exist (Feb 30, hour 24) rolls over in `Calendar`; Python rejects it.
        guard let date = calendar.date(from: components) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard check.year == year, check.month == month, check.day == day, check.hour == components.hour,
              check.minute == components.minute else { return nil }
        return (date.timeIntervalSince1970 + fraction) * 1000
    }

    /// A cursor over the text's scalars, consuming one field at a time.
    private struct Scanner {
        let scalars: [Unicode.Scalar]
        var index = 0

        var isAtEnd: Bool { index >= scalars.count }

        mutating func digits(_ count: Int) -> Int? {
            guard index + count <= scalars.count else { return nil }
            var value = 0
            for scalar in scalars[index..<(index + count)] {
                guard ("0"..."9").contains(scalar) else { return nil }
                value = value * 10 + Int(scalar.value - 48)
            }
            index += count
            return value
        }

        mutating func expect(_ scalar: Unicode.Scalar) -> Bool {
            guard index < scalars.count, scalars[index] == scalar else { return false }
            index += 1
            return true
        }

        /// `hh[:mm[:ss[.ffffff]]]` into `components`; returns the fractional second, nil when malformed.
        mutating func time(into components: inout DateComponents) -> Double? {
            guard let hour = digits(2) else { return nil }
            components.hour = hour
            guard expect(":") else { return 0 }
            guard let minute = digits(2) else { return nil }
            components.minute = minute
            guard expect(":") else { return 0 }
            guard let second = digits(2) else { return nil }
            components.second = second
            guard expect(".") || expect(",") else { return 0 }
            return fraction()
        }

        /// The digits after the decimal mark (only the first six count); nil when there are none.
        mutating func fraction() -> Double? {
            var fraction = 0.0
            var scale = 0.1
            var count = 0
            while index < scalars.count, ("0"..."9").contains(scalars[index]) {
                if count < 6 { fraction += Double(scalars[index].value - 48) * scale }
                scale /= 10
                count += 1
                index += 1
            }
            return count > 0 ? fraction : nil
        }

        /// `±hh[:]mm` or `±hh` as seconds east of UTC; nil when malformed.
        mutating func offsetSeconds() -> Int? {
            let sign: Int
            if expect("+") { sign = 1 } else if expect("-") { sign = -1 } else { return nil }
            guard let hours = digits(2) else { return nil }
            _ = expect(":")
            let minutes = digits(2) ?? 0
            return sign * (hours * 3600 + minutes * 60)
        }
    }
}
