import CryptoKit
import Foundation
import XCTest
@testable import Cotabby

/// Pins conversation memory's engine: the ingest pipeline, the scope rule suggestions rely on
/// (this conversation, then exactly the same people, never a guess), the Playground's exploring
/// search, what answers may draw on, and with the embedding model present, indexing and search by
/// meaning end to end.
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
        var thread = MemoryEngine.Scope()
        thread.conversation = ("apple_mail", "t1")
        let hits = engine.search(query: "numbers", scope: thread).hits
        XCTAssertEqual(hits.map(\.text), ["Numbers are in."])
    }

    func test_aDisabledSourceStoresNothing() throws {
        let engine = try makeEngine(sources: ["whatsapp"])
        XCTAssertEqual(try engine.ingest(source: "apple_mail", records: [record("t1", "hello")], cursor: nil).stored, 0)
    }

    /// Every removal or settings change moves the data generation the retriever's caches follow.
    func test_deletionsAndSettingChangesMoveTheDataGeneration() throws {
        let engine = try makeEngine(sources: ["whatsapp", "icloud_drive"])
        var seen = engine.dataGeneration
        func moved(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertNotEqual(engine.dataGeneration, seen, what, file: file, line: line)
            seen = engine.dataGeneration
        }
        try engine.ingest(source: "whatsapp", records: [record("c1", "the invoice is paid")], cursor: nil)
        XCTAssertEqual(engine.dataGeneration, seen, "adding is not a removal")
        try engine.updateConfiguration { $0.privacy.excludedConversations = ["c1"] }
        moved("never remember")
        try engine.forget(source: "whatsapp")
        moved("forget")
        try engine.deleteEverything()
        moved("delete all")
        try engine.ingest(source: "icloud_drive", records: [record("doc", "first section of the document")], cursor: nil)
        seen = engine.dataGeneration
        try engine.forget(source: "icloud_drive", conversationsNotIn: [])
        moved("a deleted document")
        try engine.ingest(source: "icloud_drive", records: [record("doc", "first section of the document")], cursor: nil)
        seen = engine.dataGeneration
        try engine.ingest(source: "icloud_drive", records: [], cursor: nil, completeConversations: ["doc"])
        moved("a shortened document")
    }

    /// The Documents Folder source pointed at another folder starts over: the old folder's records
    /// and cursor go, so the new folder's older files are read and nothing of the old one stays.
    func test_changingTheDocumentsFolderForgetsWhatTheOldOneGave() throws {
        let engine = try makeEngine(sources: [])
        try engine.updateConfiguration { $0.sources["documents"] = MemorySourceSettings(enabled: true, options: ["folder": "/notes/a"]) }
        try engine.ingest(source: "documents", records: [record("plan.md", "the plan for the pilot is ready")], cursor: "1790000000")
        try engine.updateConfiguration { $0.sources["documents"]?.options["note"] = "unrelated" }
        XCTAssertEqual(engine.cursor(source: "documents"), "1790000000", "another option changes nothing")
        try engine.updateConfiguration { $0.sources["documents"]?.options["folder"] = "/notes/b" }
        XCTAssertNil(engine.cursor(source: "documents"))
        XCTAssertEqual(engine.sources().first { $0.id == "documents" }?.stats.messages, 0)
    }

    /// A hand-edited settings file with a whole number beyond Int's range still loads (the value
    /// stays a Double) instead of trapping at launch; ordinary whole numbers read as integers.
    func test_aHugeOptionNumberLoads() throws {
        let url = directory.appendingPathComponent("config.json")
        try Data(#"{"sources": {"documents": {"enabled": true, "options": {"limit": 1e20, "count": 3, "ratio": 2.5}}}}"#.utf8)
            .write(to: url)
        let options = MemoryEngine.loadConfiguration(url).sources["documents"]?.options
        XCTAssertEqual(options?["count"], "3")
        XCTAssertEqual(options?["ratio"], "2.5")
        XCTAssertEqual(options?["limit"], String(1e20))
    }

    /// Shrinking the passage size takes the overlap down with it (the pane applies this on every edit).
    func test_indexSettingsClampTheOverlapToHalfAPassage() {
        var settings = MemoryIndexSettings()
        settings.chunkSize = 128
        settings.chunkOverlap = 64
        settings.chunkSize = 64
        XCTAssertEqual(settings.clamped().chunkOverlap, 32)
        settings.topK = 99
        settings.vectorWeight = -1
        XCTAssertEqual(settings.clamped().topK, 20)
        XCTAssertEqual(settings.clamped().vectorWeight, 0)
    }

    /// Removing passages moves the last row into the gap: the moved row keeps its vector exactly
    /// and every remaining passage is still found.
    func test_theVectorIndexRemovesRowsAndKeepsTheOthersIntact() {
        let index = FlatVectorIndex(dimensions: 0)
        func unit(_ axis: Int) -> [UInt16] { HalfPrecision.encode((0..<4).map { $0 == axis ? 1 : 0 }) }
        index.replaceAll((0..<4).map {
            MemoryStore.StoredVector(passageID: "p\($0)", recordID: "r\($0)", source: "chat", conversationKey: "c",
                                     timestamp: Double($0), vector: unit($0))
        })
        index.remove(recordIDs: ["r1"])
        XCTAssertEqual(index.count, 3)
        for axis in [0, 2, 3] {
            let query: [Float] = (0..<4).map { $0 == axis ? 1 : 0 }
            let best = index.search(query, limit: 1, where: { _ in true }).first
            XCTAssertEqual(best?.entry.recordID, "r\(axis)")
            XCTAssertEqual(best?.score ?? 0, 1, accuracy: 0.001)
        }
        index.remove(recordIDs: ["r0", "r3"])
        XCTAssertEqual(index.search([0, 0, 1, 0], limit: 5, where: { _ in true }).map(\.entry.recordID), ["r2"])
    }

    /// An indexing step stopped between native calls saves only the messages embedded whole.
    func test_aStoppedIndexingStepKeepsOnlyWholeMessages() {
        // Passages of messages 0, 0, 1, 2, 2, 2.
        let owners = [0, 0, 1, 2, 2, 2]
        XCTAssertEqual(MemoryEngine.wholeMessages(passageMessages: owners, embedded: 6, messageCount: 3), 3)
        XCTAssertEqual(MemoryEngine.wholeMessages(passageMessages: owners, embedded: 4, messageCount: 3), 2)
        XCTAssertEqual(MemoryEngine.wholeMessages(passageMessages: owners, embedded: 1, messageCount: 3), 0)
        XCTAssertEqual(MemoryEngine.wholeMessages(passageMessages: owners, embedded: 0, messageCount: 3), 0)
        XCTAssertEqual(MemoryEngine.wholeMessages(passageMessages: [], embedded: 0, messageCount: 2), 2)
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

    // MARK: - Answers

    func test_answerSearchUsesOnlyAnswerSourcesAndTheCurrentConversationAndNeverTheQuestion() throws {
        let engine = try makeEngine(sources: ["outlook", "whatsapp", "teams"])
        try engine.ingest(source: "outlook", records: [
            record("pilot", "The Acme pilot passed all acceptance tests", sender: "Sam", title: "Pilot - Acme"),
        ], cursor: nil)
        try engine.ingest(source: "whatsapp", records: [
            record("family", "The Acme pilot of our flight to Izmir is late", title: "Family"),
        ], cursor: nil)
        let question = record("dana", "How did the Acme pilot go?", sender: "Dana Miles", title: "Dana Miles")
        try engine.ingest(source: "teams", records: [question], cursor: nil)
        let questionID = try XCTUnwrap(engine.latestMessages(source: "teams", conversationID: "dana", limit: 1).first?.recordID)

        let result = engine.answerSearch(question: "How did the Acme pilot go?", sources: ["outlook"],
                                         currentConversation: ("teams", "dana"), excludingRecordIDs: [questionID])
        XCTAssertEqual(result.scope, "answer")
        XCTAssertEqual(result.hits.map(\.text), ["The Acme pilot passed all acceptance tests"],
                       "WhatsApp is not an answer source here, and the question is not its own answer")
    }

    /// Other conversations are opt-in: with no answer source turned on, only the conversation being
    /// answered can supply facts, and with none identified, nothing can.
    func test_answerSourcesAreOffByDefaultAndOnlyTheCurrentConversationIsSearched() throws {
        XCTAssertFalse(MemorySourceCatalog.all.contains { MemorySourceCatalog.isAnswerSource($0.id, settings: nil) })
        XCTAssertFalse(MemorySourceCatalog.isAnswerSource("outlook", settings: MemorySourceSettings(enabled: true)))
        XCTAssertTrue(MemorySourceCatalog.isAnswerSource("outlook", settings: MemorySourceSettings(enabled: true, answerSource: true)))

        let engine = try makeEngine(sources: ["outlook"])
        try engine.ingest(source: "outlook", records: [
            record("pilot", "The Acme pilot passed all acceptance tests", sender: "Sam", title: "Pilot - Acme"),
            record("board", "The Acme pilot budget is confidential", sender: "Priya", title: "Board"),
        ], cursor: nil)
        let current = engine.answerSearch(question: "How did the Acme pilot go?", sources: [],
                                          currentConversation: ("outlook", "pilot"), excludingRecordIDs: [])
        XCTAssertEqual(current.hits.map(\.text), ["The Acme pilot passed all acceptance tests"])
        XCTAssertTrue(engine.answerSearch(question: "How did the Acme pilot go?", sources: [], currentConversation: nil,
                                          excludingRecordIDs: []).hits.isEmpty)
    }

    /// Calendar events hold what a meeting is and who is in it; answers say only busy and free, so
    /// no event ever becomes a fact, even with "Use for answers" switched on for Calendar.
    func test_calendarEventsAreNeverAnswerFacts() throws {
        XCTAssertFalse(MemorySourceCatalog.isAnswerSource("calendar", settings: MemorySourceSettings(enabled: true, answerSource: true)))
        let engine = try makeEngine(sources: ["calendar"])
        try engine.ingest(source: "calendar", records: [
            record("event:1", "Meeting: Northwind restructuring review\nWhen: Thu 8 Oct 2026, 10:00–11:00", sender: "Priya",
                   title: "Northwind restructuring review"),
        ], cursor: nil)
        XCTAssertTrue(engine.answerSearch(question: "Are you free Thursday for the Northwind review?", sources: ["calendar"],
                                          currentConversation: nil, excludingRecordIDs: []).hits.isEmpty)
    }

    func test_chatsAreFoundByTitleAndReadNewestFirst() throws {
        let engine = try makeEngine(sources: ["teams"])
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        try engine.ingest(source: "teams", records: [
            record("dana", "Hi!", sender: "Dana Miles", title: "Dana Miles", at: start),
            record("dana", "Is the report ready?", sender: "Dana Miles", title: "Dana Miles", at: start.addingTimeInterval(60)),
        ], cursor: nil)
        let found = engine.findConversations(title: "Dana Miles", sources: ["teams"])
        XCTAssertEqual(found.map(\.conversationId), ["dana"])
        XCTAssertTrue(engine.findConversations(title: "Dana Miles", sources: ["outlook"]).isEmpty, "another app's sources")
        XCTAssertEqual(engine.latestMessages(source: "teams", conversationID: "dana", limit: 5).map(\.text),
                       ["Is the report ready?", "Hi!"])
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
