import CryptoKit
import Foundation
import XCTest
@testable import Cotabby

/// Pins conversation memory's encrypted store: the on-disk format (fixed known-answer values, so a
/// change that would make existing stores unreadable fails here), the scope keys, idempotent upserts,
/// filter-first keyword search, purging, and that nothing personal is readable on disk.
final class MemoryStoreTests: XCTestCase {
    private var directory: URL!
    private let key = SymmetricKey(data: Data(0..<32))

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("memory-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(key: SymmetricKey? = nil) throws -> MemoryStore {
        try MemoryStore(path: directory.appendingPathComponent("messages.sqlite"), vault: MemoryVault(rootKey: key ?? self.key))
    }

    private func record(
        _ conversation: String, _ text: String, sender: String = "Ayşe", me: Bool = false, title: String? = nil,
        participants: [String] = [], at timestamp: Date = Date(), id: String? = nil
    ) -> MemoryIngestRecord {
        MemoryIngestRecord(
            sourceMessageID: id ?? "\(conversation):\(text)", conversationID: conversation,
            conversationTitle: title ?? conversation, sender: sender, isFromMe: me, timestamp: timestamp,
            text: text, participants: participants, subject: nil
        )
    }

    // MARK: - On-disk format

    /// Known-answer values sealed and tagged with the key bytes 0..<32 (AES-256-GCM and HMAC-SHA256
    /// with the documented subkeys); they must keep opening and matching.
    func test_knownSealedValuesOpenAndTagsMatch() throws {
        let vault = MemoryVault(rootKey: key)
        let sealed = Data(hex: "80dc6f628849e8ace07efe9369c8e34f23f979564036f325faf642dc36bbb6592fe4d24d53979801bab69c57554a160d9b1ab425a2231180a2c83528bd0863")
        XCTAssertEqual(try vault.open(sealed), "Merhaba dünya, the invoice is paid")
        XCTAssertEqual(vault.tag("title\u{1f}poc results"), "195de12496601a745ae14d3ec29655f9")
        XCTAssertNoThrow(try vault.verify(Data(hex: "2c78aafa8701d9ffeda9a7904a36fd8a5b37052a99a8a60919c1e5328d796ffe3087a9a9223a0f8fbb11a80365aa0b78a4257a33f941e1")))
        let store = try makeStore()
        XCTAssertEqual(store.recordID(source: "whatsapp", sourceMessageID: "A1"), "whatsapp:3b81395c7d56517ad8b31f11f3eaf0ae")
        XCTAssertEqual(try vault.open(try vault.seal("round trip")), "round trip")
    }

    func test_aStoreOpenedWithAnotherKeyIsRefused() throws {
        _ = try makeStore()
        XCTAssertThrowsError(try makeStore(key: SymmetricKey(data: Data(repeating: 0, count: 32))))
    }

    // MARK: - Writing

    func test_participantsNeverIncludeTheUser() throws {
        let store = try makeStore()
        try store.upsert(source: "chat", records: [
            record("c1", "hello there friend", sender: "Me", me: true, participants: ["Ayşe"]),
            record("c1", "hi back to you", sender: "Ayşe"),
        ])
        XCTAssertEqual(try store.conversation(source: "chat", conversationID: "c1")?.participants, ["ayşe"])
    }

    /// A mail's people are its addresses: a display name is the sender's to choose and never an
    /// identity that could match someone else's conversations.
    func test_aMailSendersDisplayNameIsNeverAParticipant() throws {
        let store = try makeStore()
        try store.upsert(source: "apple_mail", records: [
            MemoryIngestRecord(sourceMessageID: "m1", conversationID: "t1", conversationTitle: "Budget", sender: "Ayşe",
                               isFromMe: false, timestamp: Date(), text: "send the numbers",
                               participants: ["mallory@example.org"], subject: "Budget")
        ])
        XCTAssertEqual(try store.conversation(source: "apple_mail", conversationID: "t1")?.participants, ["mallory@example.org"])
    }

    func test_upsertIsIdempotentAndEditsNeedIndexingAgain() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.upsert(source: "chat", records: [record("c1", "original text here", id: "m1")]).changed, 1)
        let message = try XCTUnwrap(try store.unindexedMessages(sources: ["chat"], limit: 10).first)
        try store.saveIndexEntries([(message, [("p1", HalfPrecision.encode([0.5, 0.5, 0.5, 0.5]))])], model: "m")
        XCTAssertEqual(try store.unindexedCount(sources: ["chat"]), 0)
        XCTAssertEqual(try store.upsert(source: "chat", records: [record("c1", "original text here", id: "m1")]).changed, 0)
        XCTAssertEqual(try store.upsert(source: "chat", records: [record("c1", "edited text here", id: "m1")]).replacedRecordIDs.count, 1)
        XCTAssertEqual(try store.unindexedMessages(sources: ["chat"], limit: 10).map(\.text), ["edited text here"])
        XCTAssertTrue(try store.vectors(model: "m").isEmpty, "an edited message loses its old vector")
    }

    /// A message edited, moved or deleted while it was being embedded keeps its new state: the old
    /// snapshot's vectors are not saved, and it stays pending.
    func test_indexingNeverSavesAMessageThatChangedWhileItWasEmbedded() throws {
        let store = try makeStore()
        try store.upsert(source: "chat", records: [record("c1", "original text here", id: "m1"), record("c1", "second message", id: "m2")])
        let snapshot = try store.unindexedMessages(sources: ["chat"], limit: 10)
        try store.upsert(source: "chat", records: [record("c1", "edited text here", id: "m1")])
        let vector = HalfPrecision.encode([0.5, 0.5, 0.5, 0.5])
        let saved = try store.saveIndexEntries(snapshot.map { ($0, [("p-" + $0.recordID, vector)]) }, model: "m")
        let edited = store.recordID(source: "chat", sourceMessageID: "m1")
        XCTAssertFalse(saved.contains(edited))
        XCTAssertEqual(saved, [store.recordID(source: "chat", sourceMessageID: "m2")])
        XCTAssertEqual(try store.unindexedMessages(sources: ["chat"], limit: 10).map(\.text), ["edited text here"])
        XCTAssertEqual(try store.keywordSearch(query: "edited", conversations: [
            (source: "chat", conversationKey: store.conversationKey(source: "chat", conversationID: "c1"))
        ], limit: 5).map(\.recordID), [edited], "the edit's terms survive")
        try store.deleteSource("chat")
        XCTAssertTrue(try store.saveIndexEntries(snapshot.map { ($0, [("p-" + $0.recordID, vector)]) }, model: "m").isEmpty,
                      "a deleted message gets no vectors back")
        XCTAssertTrue(try store.vectors(model: "m").isEmpty)
    }

    /// A later read can move a message to another conversation (a corrected mail audience) or
    /// correct who wrote it; the stored message follows, and an emptied conversation goes.
    func test_aMessageMovedOrReattributedIsUpdated() throws {
        let store = try makeStore()
        try store.upsert(source: "chat", records: [record("A", "the invoice is paid", title: "Alpha", id: "m1")])
        try store.upsert(source: "chat", records: [record("B", "the invoice is paid", me: true, title: "Beta", id: "m1")])
        XCTAssertTrue(try store.findConversations(title: "Alpha", sources: ["chat"]).isEmpty, "the emptied conversation is gone")
        let beta = try XCTUnwrap(try store.findConversations(title: "Beta", sources: ["chat"]).first)
        XCTAssertEqual(beta.conversationId, "B")
        let message = try XCTUnwrap(try store.unindexedMessages(sources: ["chat"], limit: 5).first)
        XCTAssertEqual(message.conversationKey, store.conversationKey(source: "chat", conversationID: "B"))
        XCTAssertTrue(message.isFromMe)
    }

    /// Purging an excluded person or conversation leaves no conversation row (sealed title, title
    /// tag) or participant row behind, only the conversations that still hold messages.
    func test_purgeRemovesTheConversationsItEmpties() throws {
        let store = try makeStore()
        try store.upsert(source: "chat", records: [
            record("c1", "from the boss", sender: "Boss", title: "Boss", participants: ["Boss"]),
            record("c2", "lunch at noon", sender: "Can", title: "Can", participants: ["Can"])
        ])
        XCTAssertEqual(try store.purge(excludedConversations: [], excludedParticipants: ["Boss"], olderThan: nil), 1)
        XCTAssertTrue(try store.findConversations(title: "Boss", sources: ["chat"]).isEmpty)
        XCTAssertNil(try store.conversation(source: "chat", conversationID: "c1"))
        XCTAssertTrue(try store.conversationsSeenBy(audience: ["boss"], excluding: ("chat", "")).isEmpty)
        XCTAssertEqual(try store.findConversations(title: "Can", sources: ["chat"]).count, 1)
        XCTAssertEqual(try store.purge(excludedConversations: ["c2"], excludedParticipants: [], olderThan: nil), 1)
        XCTAssertNil(try store.conversation(source: "chat", conversationID: "c2"))
    }

    func test_vectorsRoundTripAndAnotherModelsVectorsAreDropped() throws {
        let store = try makeStore()
        try store.upsert(source: "chat", records: [record("c1", "the invoice is paid")])
        let message = try XCTUnwrap(try store.unindexedMessages(sources: ["chat"], limit: 1).first)
        let vector = HalfPrecision.encode([0.25, -0.5, 1, 0])
        try store.saveIndexEntries([(message, [("p1", vector)])], model: "old-model")
        XCTAssertEqual(try store.vectors(model: "old-model").first?.vector, vector)
        XCTAssertEqual(try store.invalidateVectors(notMadeBy: "new-model"), 1)
        XCTAssertTrue(try store.vectors(model: "old-model").isEmpty)
    }

    func test_purgeRemovesExcludedPeopleAndExpiredMessages() throws {
        let store = try makeStore()
        let old = Date().addingTimeInterval(-400 * 86_400)
        try store.upsert(source: "chat", records: [
            record("c1", "from the boss today", sender: "Boss"),
            record("c2", "an old message here", at: old),
            record("c3", "a fresh message here"),
        ])
        let removed = try store.purge(excludedConversations: [], excludedParticipants: ["boss"],
                                      olderThan: Date().addingTimeInterval(-365 * 86_400).timeIntervalSince1970)
        XCTAssertEqual(removed, 2)
        XCTAssertEqual(try store.unindexedMessages(sources: ["chat"], limit: 10).map(\.conversationID), ["c3"])
    }

    // MARK: - Reading

    func test_keywordSearchNeverLeavesTheGivenConversationsAndMatchesPrefixes() throws {
        let store = try makeStore()
        try store.upsert(source: "chat", records: [
            record("c1", "the invoice is paid"), record("c1", "lunch tomorrow"), record("c2", "the invoice is late", sender: "Can"),
        ])
        let scope = [(source: "chat", conversationKey: store.conversationKey(source: "chat", conversationID: "c1"))]
        XCTAssertEqual(try store.keywordSearch(query: "invo", conversations: scope, limit: 5).map(\.text), ["the invoice is paid"])
    }

    func test_titlesFindConversationsOnlyInTheGivenSources() throws {
        let store = try makeStore()
        try store.upsert(source: "apple_mail", records: [record("t1", "numbers are in", title: "POC results")])
        try store.upsert(source: "whatsapp", records: [record("w1", "hi", title: "POC results")])
        XCTAssertEqual(try store.findConversations(title: "Re: poc results", sources: ["apple_mail"]).map(\.source), ["apple_mail"])
    }

    func test_sameAudienceNeedsExactlyTheSamePeople() throws {
        let store = try makeStore()
        try store.upsert(source: "chat", records: [record("dm", "private note", me: true, participants: ["Avery"])])
        try store.upsert(source: "chat", records: [record("group", "group note", me: true, participants: ["Avery", "Vic"])])
        try store.upsert(source: "mail", records: [record("thread", "mail to avery", me: true, participants: ["avery"])])
        let seen = try store.conversationsSeenBy(audience: ["Avery"], excluding: nil)
        XCTAssertEqual(Set(seen.map(\.source)), ["chat", "mail"])
        XCTAssertFalse(seen.contains { $0.conversationKey == store.conversationKey(source: "chat", conversationID: "group") })
    }

    func test_taggedKeywordSearchFindsWholeWordsAcrossConversations() throws {
        let store = try makeStore()
        try store.upsert(source: "outlook", records: [
            record("t1", "Acme POC passed all acceptance tests"), record("t2", "lunch on friday"),
        ])
        let messages = try store.unindexedMessages(sources: ["outlook"], limit: 10)
        try store.saveIndexEntries(messages.map { ($0, []) }, model: "m")
        let hits = try store.taggedKeywordSearch(query: "how did the Acme POC go?", sources: ["outlook"], limit: 5)
        XCTAssertEqual(try hits.compactMap { try store.message(recordID: $0)?.text }, ["Acme POC passed all acceptance tests"])
        XCTAssertTrue(try store.taggedKeywordSearch(query: "Acme", sources: ["whatsapp"], limit: 5).isEmpty)
    }

    func test_nothingPersonalIsReadableOnDisk() throws {
        let store = try makeStore()
        let marker = "Zyxwvut-secret-plan"
        try store.upsert(source: "whatsapp", records: [
            record("whatsapp-ayse", "the \(marker) is ready", sender: "Ayşe Yılmaz", title: "Ayşe Yılmaz", participants: ["ayse@example.com"]),
        ])
        let message = try XCTUnwrap(try store.unindexedMessages(sources: ["whatsapp"], limit: 1).first)
        try store.saveIndexEntries([(message, [("p1", HalfPrecision.encode([1, 2, 3]))])], model: "m")
        try store.setCursor("cursor-\(marker)", source: "whatsapp")
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let data = try Data(contentsOf: file)
            for secret in [marker, "Ayşe", "ayse@example.com", "whatsapp-ayse", "secret", "ready"] {
                XCTAssertNil(data.range(of: Data(secret.utf8)), "\(secret) readable in \(file.lastPathComponent)")
            }
        }
    }
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}
