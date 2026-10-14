import CryptoKit
import Foundation
import XCTest
@testable import Cotabby

/// Pins conversation memory's engine: the ingest pipeline, the scope rule suggestions rely on
/// (this conversation, then exactly the same people, never a guess), the Playground's exploring
/// search, and with the embedding model present, indexing and search by meaning end to end.
///
/// Without a model the engine searches by keywords only (the index is empty), which pins every
/// scope rule exactly and runs in milliseconds.
final class MemoryEngineTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("memory-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeEngine(sources: [String], modelURL: URL? = nil) throws -> MemoryEngine {
        let engine = try MemoryEngine(
            paths: MemoryEngine.Paths(dataDirectory: directory),
            rootKey: SymmetricKey(data: Data(0..<32)),
            modelURL: modelURL ?? directory.appendingPathComponent("none.gguf"),
            conditions: {
                EmbeddingSchedulePolicy.Conditions(isOnACPower: true, isLowPowerMode: false, thermalState: .nominal,
                                                   userIdleSeconds: 60, isGenerating: false, pendingPassages: 0)
            }
        )
        try engine.updateConfiguration { configuration in
            for source in sources { configuration.sources[source] = MemorySourceSettings(enabled: true) }
            configuration.index.vectorWeight = modelURL == nil ? 0 : 0.7
        }
        return engine
    }

    private func record(
        _ conversation: String, _ text: String, sender: String = "Ayşe", me: Bool = false, title: String? = nil,
        participants: [String] = [], at timestamp: Date = Date(), subject: String? = nil
    ) -> MemoryIngestRecord {
        MemoryIngestRecord(
            sourceMessageID: "\(conversation):\(text)", conversationID: conversation, conversationTitle: title ?? conversation,
            sender: sender, isFromMe: me, timestamp: timestamp, text: text, participants: participants, subject: subject
        )
    }

    private func scope(_ title: String, _ sources: [String]) -> MemoryEngine.Scope {
        var scope = MemoryEngine.Scope()
        scope.title = title
        scope.sources = sources
        return scope
    }

    // MARK: - Ingest

    func test_ingestDropsSecretsExclusionsAndExpiredMessagesAndStripsMailQuotes() throws {
        let engine = try makeEngine(sources: ["whatsapp", "apple_mail"])
        try engine.updateConfiguration { $0.privacy.excludedParticipants = ["Boss"] }
        let result = try engine.ingest(source: "whatsapp", records: [
            record("c1", "the invoice is paid", participants: ["Ayşe"]),
            record("c1", "Your verification code is 482913"),
            record("c2", "from the boss", sender: "Boss"),
            record("c3", "an old message", at: Date().addingTimeInterval(-400 * 86_400)),
        ], cursor: "4")
        XCTAssertEqual(result, MemoryEngine.IngestResult(stored: 1, dropped: 3))
        XCTAssertEqual(engine.cursor(source: "whatsapp"), "4")

        try engine.ingest(source: "apple_mail", records: [
            record("t1", "Numbers are in.\n\nOn Mon, Ayşe wrote:\n> old quoted text", title: "POC", subject: "POC")
        ], cursor: nil)
        let hits = engine.search(query: "numbers", scope: scope("POC", ["apple_mail"])).hits
        XCTAssertEqual(hits.map(\.text), ["Numbers are in."])
    }

    func test_aDisabledSourceStoresNothing() throws {
        let engine = try makeEngine(sources: ["whatsapp"])
        XCTAssertEqual(try engine.ingest(source: "apple_mail", records: [record("t1", "hello")], cursor: nil).stored, 0)
    }

    // MARK: - Scope rule

    func test_searchStaysInTheConversationThenTheSamePeople() throws {
        let engine = try makeEngine(sources: ["whatsapp", "apple_mail"])
        try engine.ingest(source: "whatsapp", records: [
            record("ayse-dm", "the invoice is paid", title: "Ayşe", participants: ["Ayşe"]),
            record("can-dm", "the invoice is late", sender: "Can", title: "Can", participants: ["Can"]),
        ], cursor: nil)
        try engine.ingest(source: "apple_mail", records: [
            record("thread", "invoice number 4417", title: "Invoice", participants: ["Ayşe"]),
        ], cursor: nil)

        let own = engine.search(query: "invoice", scope: scope("Ayşe", ["whatsapp"]), topK: 1)
        XCTAssertEqual(own.scope, "conversation")
        XCTAssertEqual(own.hits.map(\.text), ["the invoice is paid"])

        let widened = engine.search(query: "invoice", scope: scope("Ayşe", ["whatsapp"]), topK: 4)
        XCTAssertEqual(widened.scope, "person")
        XCTAssertEqual(Set(widened.hits.map(\.text)), ["the invoice is paid", "invoice number 4417"],
                       "Ayşe's mail thread, never Can's chat")
    }

    func test_unknownAmbiguousOrForeignAppTitlesFindNothing() throws {
        let engine = try makeEngine(sources: ["whatsapp", "apple_mail"])
        try engine.ingest(source: "whatsapp", records: [
            record("avery-1", "the budget is fixed", sender: "Avery", title: "Avery"),
            record("avery-2", "the budget is late", sender: "Avery B", title: "Avery"),
        ], cursor: nil)
        XCTAssertEqual(engine.search(query: "budget", scope: scope("Avery", ["whatsapp"])).scope, "none", "two chats called Avery")
        XCTAssertEqual(engine.search(query: "budget", scope: scope("Nobody", ["whatsapp"])).hits, [])
        XCTAssertEqual(engine.search(query: "budget", scope: scope("Avery", ["apple_mail"])).hits, [], "titles never cross apps")
    }

    /// Same subject, different people: a mail reply whose quoted sender is not in the stored thread
    /// is a different conversation, whatever its subject.
    func test_aSharedSubjectWithOtherPeopleIsNotTheSameThread() throws {
        let engine = try makeEngine(sources: ["apple_mail"])
        try engine.ingest(source: "apple_mail", records: [
            record("t1", "the invoice total is 300 EUR", sender: "Ayşe", title: "Invoice",
                   participants: ["ayse@example.com"], subject: "Invoice")
        ], cursor: nil)
        var other = scope("Re: Invoice", ["apple_mail"])
        other.requiredParticipants = ["bob@example.org"]
        XCTAssertEqual(engine.search(query: "invoice", scope: other).scope, "none")
        XCTAssertTrue(engine.search(query: "invoice", scope: other).hits.isEmpty)

        var same = scope("Re: Invoice", ["apple_mail"])
        same.requiredParticipants = ["Ayşe Yılmaz <AYSE@example.com>"]
        XCTAssertEqual(engine.search(query: "invoice", scope: same).hits.map(\.text), ["the invoice total is 300 EUR"])
    }

    /// The people a reply quotes, as far as memory knows them, must be exactly the thread's people:
    /// a reply to part of a group or with someone new gets nothing; the user's own address, which
    /// memory never stores as a participant, does not count.
    func test_aMailReplyNeedsExactlyTheThreadsPeople() throws {
        let engine = try makeEngine(sources: ["apple_mail"])
        try engine.ingest(source: "apple_mail", records: [
            record("t1", "the budget is approved", sender: "Ayşe", title: "Budget",
                   participants: ["ayse@example.com", "bob@example.com"], subject: "Budget"),
            record("t2", "lunch at noon", sender: "Carol", title: "Lunch", participants: ["carol@example.com"], subject: "Lunch")
        ], cursor: nil)
        func reply(quoting addresses: Set<String>) -> MemorySearchResult {
            var scope = scope("Re: Budget", ["apple_mail"])
            scope.requiredParticipants = addresses
            return engine.search(query: "budget", scope: scope)
        }
        XCTAssertEqual(reply(quoting: ["ayse@example.com"]).scope, "none", "part of the thread's people")
        XCTAssertEqual(reply(quoting: ["ayse@example.com", "bob@example.com", "carol@example.com"]).scope, "none",
                       "someone known from another thread is not in this one")
        XCTAssertEqual(reply(quoting: ["ayse@example.com", "bob@example.com", "me@example.org"]).hits.map(\.text),
                       ["the budget is approved"], "exactly its people; the unknown own address drops out")
        XCTAssertEqual(reply(quoting: ["me@example.org"]).scope, "none", "nobody memory knows")
    }

    /// One Mail thread, two audiences (a stranger joined it by headers): a reply picks the
    /// conversation with exactly its quoted people, and the stranger never gets the history.
    func test_aMailReplyPicksTheThreadWithExactlyItsPeople() throws {
        let engine = try makeEngine(sources: ["apple_mail"])
        try engine.ingest(source: "apple_mail", records: [
            record("77|ayse@example.com", "the budget is 40,000, keep it between us", sender: "Ayşe", title: "Budget",
                   participants: ["ayse@example.com"], subject: "Budget"),
            record("77|mallory@example.org", "what is the budget?", sender: "Ayşe", title: "Budget",
                   participants: ["mallory@example.org"], subject: "Budget")
        ], cursor: nil)
        func reply(quoting address: String) -> MemorySearchResult {
            var scope = scope("Re: Budget", ["apple_mail"])
            scope.requiredParticipants = [address]
            return engine.search(query: "budget", scope: scope, topK: 4)
        }
        XCTAssertEqual(reply(quoting: "ayse@example.com").hits.map(\.text), ["the budget is 40,000, keep it between us"])
        XCTAssertEqual(reply(quoting: "mallory@example.org").hits.map(\.text), ["what is the budget?"],
                       "the stranger's own conversation only, even though she used Ayşe's name")
    }

    /// Titles match whole (after case, space and reply-prefix normalization), never in part.
    func test_aPartialTitleIsNotTheConversation() throws {
        let engine = try makeEngine(sources: ["whatsapp"])
        try engine.ingest(source: "whatsapp", records: [record("c1", "the invoice is paid", title: "Ayşe Yılmaz")], cursor: nil)
        XCTAssertEqual(engine.search(query: "invoice", scope: scope("Ayşe", ["whatsapp"])).scope, "none")
        XCTAssertEqual(engine.search(query: "invoice", scope: scope("Ayşe Yılmaz Office", ["whatsapp"])).scope, "none")
        XCTAssertEqual(engine.search(query: "invoice", scope: scope("  ayşe   yılmaz ", ["whatsapp"])).scope, "conversation")
    }

    /// A WhatsApp group whose only other member is Ayşe still never shares memory with the 1:1 chat
    /// with her (the group marker the reader adds), in either direction.
    func test_aWhatsAppGroupNeverWidensIntoAOneToOneChat() throws {
        let engine = try makeEngine(sources: ["whatsapp"])
        let ayse = "15550100001@s.whatsapp.net"
        try engine.ingest(source: "whatsapp", records: [
            record(ayse, "my invoice question is private", title: "Ayşe", participants: [ayse]),
            record("12036@g.us", "the trip invoice is shared", title: "Trip",
                   participants: [ayse, "whatsapp-group:12036@g.us"])  // the marker WhatsAppHistoryReader adds
        ], cursor: nil)
        let direct = engine.search(query: "invoice", scope: scope("Ayşe", ["whatsapp"]), topK: 4)
        XCTAssertEqual(direct.hits.map(\.text), ["my invoice question is private"])
        XCTAssertEqual(direct.scope, "conversation")
        let group = engine.search(query: "invoice", scope: scope("Trip", ["whatsapp"]), topK: 4)
        XCTAssertEqual(group.hits.map(\.text), ["the trip invoice is shared"])
    }

    func test_disabledSourcesAreNeverSearched() throws {
        let engine = try makeEngine(sources: ["whatsapp"])
        try engine.ingest(source: "whatsapp", records: [record("c1", "the invoice is paid", title: "Ayşe")], cursor: nil)
        try engine.updateConfiguration { $0.sources["whatsapp"]?.enabled = false }
        XCTAssertEqual(engine.search(query: "invoice", scope: scope("Ayşe", ["whatsapp"])).hits, [])
    }

    func test_teamsGroupsNeverShareMemoryWithOneToOneChats() throws {
        let engine = try makeEngine(sources: ["teams"])
        try engine.ingest(source: "teams", records: [
            record("dm", "my salary negotiation is private", sender: "Avery Stone", title: "Avery Stone", participants: ["8:orgid:avery"]),
            record("group", "the release is on Friday", sender: "Avery Stone", title: "Ops",
                   participants: ["8:orgid:avery", "teams-group:group"]),
        ], cursor: nil)
        XCTAssertTrue(engine.search(query: "salary", scope: scope("Ops", ["teams"])).hits.isEmpty)
        XCTAssertTrue(engine.search(query: "release", scope: scope("Avery Stone", ["teams"])).hits.isEmpty)
    }

    // MARK: - Exploring search (Playground)

    func test_exploringSearchCoversOnlyTheRequestedEnabledSources() throws {
        let engine = try makeEngine(sources: ["outlook", "whatsapp"])
        try engine.ingest(source: "outlook", records: [
            record("pilot", "The pilot passed all acceptance tests", sender: "Sam", title: "Pilot - Acme"),
        ], cursor: nil)
        try engine.ingest(source: "whatsapp", records: [
            record("family", "The pilot of our flight to Izmir is late", title: "Family"),
        ], cursor: nil)

        var outlookOnly = MemoryEngine.Scope()
        outlookOnly.global = true
        outlookOnly.sources = ["outlook"]
        let result = engine.search(query: "pilot", scope: outlookOnly)
        XCTAssertEqual(result.scope, "global")
        XCTAssertEqual(result.hits.map(\.text), ["The pilot passed all acceptance tests"])

        var everything = MemoryEngine.Scope()
        everything.global = true
        XCTAssertEqual(engine.search(query: "pilot", scope: everything).hits.count, 2, "no sources means every enabled one")
        var disabled = MemoryEngine.Scope()
        disabled.global = true
        disabled.sources = ["teams"]
        XCTAssertTrue(engine.search(query: "pilot", scope: disabled).hits.isEmpty, "a source that is off is never searched")
    }

    // MARK: - Schedule policy

    func test_schedulePolicyRunsSmallDeltasAnytimeAndBacklogsOnlyWhenPluggedInIdleAndCool() {
        var conditions = EmbeddingSchedulePolicy.Conditions(
            isOnACPower: false, isLowPowerMode: false, thermalState: .nominal, userIdleSeconds: 0,
            isGenerating: false, pendingPassages: 50
        )
        XCTAssertEqual(EmbeddingSchedulePolicy.decide(conditions), .run)
        conditions.pendingPassages = 5_000
        XCTAssertNotEqual(EmbeddingSchedulePolicy.decide(conditions), .run, "a backlog waits for power")
        conditions.isOnACPower = true
        XCTAssertNotEqual(EmbeddingSchedulePolicy.decide(conditions), .run, "and for the user to pause")
        conditions.userIdleSeconds = 60
        XCTAssertEqual(EmbeddingSchedulePolicy.decide(conditions), .run)
        conditions.thermalState = .serious
        XCTAssertNotEqual(EmbeddingSchedulePolicy.decide(conditions), .run)
        conditions.thermalState = .nominal
        conditions.isLowPowerMode = true
        XCTAssertNotEqual(EmbeddingSchedulePolicy.decide(conditions), .run)
        conditions.isLowPowerMode = false
        conditions.isGenerating = true
        XCTAssertNotEqual(EmbeddingSchedulePolicy.decide(conditions), .run)
        conditions.pendingPassages = 0
        XCTAssertEqual(EmbeddingSchedulePolicy.decide(conditions), .wait("Nothing to index"))
    }

    // MARK: - With the embedding model

    /// Indexing and search by meaning end to end (`COTABBY_TEST_EMBEDDING_MODEL_PATH`).
    func test_indexedMessagesAreFoundByMeaningWithinTheirScope() async throws {
        guard let path = ProcessInfo.processInfo.environment["COTABBY_TEST_EMBEDDING_MODEL_PATH"],
              FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Set COTABBY_TEST_EMBEDDING_MODEL_PATH to the embedding .gguf to run this test")
        }
        let engine = try makeEngine(sources: ["whatsapp"], modelURL: URL(fileURLWithPath: path))
        try engine.start()
        defer { engine.stop() }
        try engine.ingest(source: "whatsapp", records: [
            record("ayse", "The September invoice was paid by bank transfer.", title: "Ayşe", participants: ["Ayşe"]),
            record("ayse", "Yarın saat üçte Karaköy'de buluşalım.", title: "Ayşe", participants: ["Ayşe"]),
            record("can", "My invoice for September is still unpaid.", sender: "Can", title: "Can", participants: ["Can"]),
        ], cursor: nil)
        let deadline = Date().addingTimeInterval(30)
        while engine.status.passages < 3, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(engine.status.passages, 3)

        let result = engine.search(query: "was the payment made?", scope: scope("Ayşe", ["whatsapp"]), topK: 1)
        XCTAssertEqual(result.hits.first?.text, "The September invoice was paid by bank transfer.",
                       "found by meaning: 'payment' appears in neither message")
        XCTAssertGreaterThan(result.hits.first?.similarity ?? 0, 0.3)
        let turkish = engine.search(query: "when do we meet tomorrow", scope: scope("Ayşe", ["whatsapp"]), topK: 1)
        XCTAssertEqual(turkish.hits.first?.text, "Yarın saat üçte Karaköy'de buluşalım.", "across languages")
    }
}
