import CryptoKit
import XCTest
@testable import Cotabby

/// Keeps vault keys in memory so tests never touch the developer's login Keychain.
private final class InMemoryKeyStore: TypingHistoryKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?

    func existingKey() throws -> SymmetricKey? { lock.withLock { key } }
    func createKey() throws -> SymmetricKey {
        lock.withLock {
            let created = SymmetricKey(size: .bits256)
            key = created
            return created
        }
    }
    func deleteKey() throws { lock.withLock { key = nil } }
}

@MainActor
final class TypingHistoryStoreTests: XCTestCase {
    /// App-target MainActor classes crash the app-hosted runner when deallocated; keep them alive.
    private static var retained: [AnyObject] = []

    private var directory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("typing-history-\(UUID().uuidString)")
        suiteName = "cotabby.test.typingHistory.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeVault(keyStore: InMemoryKeyStore = InMemoryKeyStore()) -> TypingHistoryVault {
        TypingHistoryVault(fileURL: directory.appendingPathComponent("TypingHistory.sealed"), keyStore: keyStore)
    }

    private func makeStore(vault: TypingHistoryVault? = nil) -> TypingHistoryStore {
        let store = TypingHistoryStore(vault: vault ?? makeVault(), userDefaults: defaults, loadsArchive: false)
        Self.retained.append(store)
        return store
    }

    private func writeExport(_ rows: [[String: Any]]) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("user_inputs.json")
        try JSONSerialization.data(withJSONObject: rows).write(to: url)
        return url
    }

    private func signOffRows(count: Int) -> [[String: Any]] {
        (0..<count).map { index in
            ["appBundleIdentifier": "com.microsoft.Outlook",
             "textUpToCursor": "Topic \(index): the Imperum POC with Sentinel is going well.\nThanks!\nBest regards, Senad"]
        }
    }

    // MARK: - Vault

    func test_vaultRoundTripsAndTheFileHoldsNoPlaintext() throws {
        let vault = makeVault()
        let record = TypingHistoryRecord(
            id: UUID(), bundleIdentifier: "com.apple.mail", domain: nil, createdAt: Date(), updatedAt: Date(),
            text: "A very private sentence about the Imperum POC.", source: .recorded
        )

        try vault.save([record])

        XCTAssertEqual(try vault.load(), [record])
        let bytes = try Data(contentsOf: vault.fileURL)
        XCTAssertNil(bytes.range(of: Data("private sentence".utf8)))
    }

    func test_vaultWithoutItsKeyReportsCorruptionInsteadOfEmpty() throws {
        let keyStore = InMemoryKeyStore()
        let vault = makeVault(keyStore: keyStore)
        try vault.save([])
        try keyStore.deleteKey()

        XCTAssertThrowsError(try vault.load())
    }

    // MARK: - Preferences

    func test_preferencesDefaultOffAndPersist() {
        let store = makeStore()
        XCTAssertEqual(store.preferences, .defaults)

        store.setUsingHistory(true)
        store.setRecording(true)
        store.setExcluded("net.whatsapp.WhatsApp", excluded: true)

        let reloaded = makeStore()
        XCTAssertTrue(reloaded.preferences.isUsingHistory)
        XCTAssertTrue(reloaded.preferences.isRecording)
        XCTAssertEqual(reloaded.preferences.excludedBundleIdentifiers, ["net.whatsapp.WhatsApp"])
    }

    // MARK: - Import and use

    func test_importMakesHistoryUsableAndReimportAddsNothing() async throws {
        let store = makeStore()
        store.setUsingHistory(true)
        let url = try writeExport(signOffRows(count: 6))

        await store.importCotypistExport(from: url)
        XCTAssertEqual(store.recordCount, 6)
        await store.importCotypistExport(from: url)
        XCTAssertEqual(store.recordCount, 6)
        XCTAssertEqual(store.lastImportMessage, "Imported 0 entries (6 were already in your history).")

        let request = CotabbyTestFixtures.suggestionRequest(precedingText: "Thanks!\nBest regards, ")
        await waitUntil { store.phraseContinuation(for: request, engine: .appleIntelligence) != nil }
        XCTAssertEqual(store.phraseContinuation(for: request, engine: .appleIntelligence), "Senad")

        let context = CotabbyTestFixtures.focusedInputContext(
            bundleIdentifier: "com.microsoft.Outlook",
            precedingText: "Topic update: the Imperum POC with Sentinel is going well, the connectors look fine and stable today "
        )
        XCTAssertFalse(store.historyExamples(for: context, engine: .llamaOpenSource).isEmpty)
    }

    func test_historyIsNeverOfferedToTheEndpointOrWhenTurnedOff() async throws {
        let store = makeStore()
        store.setUsingHistory(true)
        await store.importCotypistExport(from: try writeExport(signOffRows(count: 6)))
        let request = CotabbyTestFixtures.suggestionRequest(precedingText: "Thanks!\nBest regards, ")
        await waitUntil { store.phraseContinuation(for: request, engine: .appleIntelligence) != nil }
        let context = CotabbyTestFixtures.focusedInputContext(
            bundleIdentifier: "com.microsoft.Outlook",
            precedingText: "Topic update: the Imperum POC with Sentinel is going well, the connectors look fine and stable today "
        )

        XCTAssertNil(store.phraseContinuation(for: request, engine: .openAICompatible))
        XCTAssertEqual(store.historyExamples(for: context, engine: .openAICompatible), [])

        store.setUsingHistory(false)
        XCTAssertNil(store.phraseContinuation(for: request, engine: .appleIntelligence))
        XCTAssertEqual(store.historyExamples(for: context, engine: .llamaOpenSource), [])
    }

    func test_importPersistsEncryptedAndReloads() async throws {
        let vault = makeVault()
        let store = makeStore(vault: vault)
        await store.importCotypistExport(from: try writeExport(signOffRows(count: 3)))
        store.flush()

        let reloaded = makeStore(vault: vault)
        await reloaded.loadArchive()
        XCTAssertEqual(reloaded.recordCount, 3)
    }

    func test_unrecognizedFileReportsAnErrorAndAddsNothing() async throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("other.json")
        try Data("{\"x\":1}".utf8).write(to: url)

        await store.importCotypistExport(from: url)

        XCTAssertEqual(store.recordCount, 0)
        XCTAssertEqual(store.lastImportMessage, CotypistExportImporter.ImportError.unrecognizedFormat.errorDescription)
    }

    // MARK: - Recording

    private func focus(_ text: String, element: String = "field", app: String = "com.apple.mail", isSecure: Bool = false) -> FocusSnapshot {
        let input = CotabbyTestFixtures.focusedInputSnapshot(
            bundleIdentifier: app, elementIdentifier: element, precedingText: text, isSecure: isSecure
        )
        return FocusSnapshot(applicationName: "Mail", bundleIdentifier: app, capability: .supported, context: input)
    }

    func test_recordingCapturesAFieldOnceFocusMovesOn() {
        let store = makeStore()
        store.setRecording(true)

        store.observe(focus("Hi Arnaud, the Imperum POC")) { true }
        store.observe(focus("Hi Arnaud, the Imperum POC is ready for review.")) { true }
        XCTAssertEqual(store.recordCount, 0, "The field being typed in is not committed yet")

        store.observe(focus("", element: "other")) { true }
        XCTAssertEqual(store.recordCount, 1)
    }

    func test_recordingSkipsSecureFieldsExcludedAppsAndDisallowedContexts() {
        let store = makeStore()
        store.setRecording(true)
        store.setExcluded("net.whatsapp.WhatsApp", excluded: true)

        store.observe(focus("correct horse battery staple password", isSecure: true)) { true }
        store.observe(focus("", element: "x")) { true }
        store.observe(focus("a long private chat message in WhatsApp", app: "net.whatsapp.WhatsApp")) { true }
        store.observe(focus("", element: "y")) { true }
        store.observe(focus("text typed while Cotabby is paused for now")) { false }
        store.observe(focus("", element: "z")) { true }

        XCTAssertEqual(store.recordCount, 0)
    }

    func test_recordingOffRecordsNothing() {
        let store = makeStore()

        store.observe(focus("Hi Arnaud, the Imperum POC is ready for review.")) { true }
        store.observe(focus("", element: "other")) { true }

        XCTAssertEqual(store.recordCount, 0)
    }

    func test_aFieldThatBlinksUnsupportedResumesTheSameRecord() {
        let store = makeStore()
        store.setRecording(true)
        let unsupported = FocusSnapshot(applicationName: "Mail", bundleIdentifier: "com.apple.mail", capability: .unsupported("blip"), context: nil)

        store.observe(focus("Hi Arnaud, the Imperum POC is ready")) { true }
        store.observe(unsupported) { true }
        store.observe(focus("Hi Arnaud, the Imperum POC is ready for review.")) { true }
        store.observe(focus("", element: "other")) { true }

        XCTAssertEqual(store.recordCount, 1)
    }

    func test_deleteAllRemovesRecordsAndTheFile() async throws {
        let vault = makeVault()
        let store = makeStore(vault: vault)
        await store.importCotypistExport(from: try writeExport(signOffRows(count: 3)))
        store.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.fileURL.path))

        store.deleteAll()

        XCTAssertEqual(store.recordCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.fileURL.path))
    }

    func test_countsByAppAndPerAppDeleteKeepOtherApps() async throws {
        let store = makeStore()
        var rows = signOffRows(count: 3)
        rows.append(["appBundleIdentifier": "net.whatsapp.WhatsApp", "textUpToCursor": "See you tomorrow at the office then!"])
        await store.importCotypistExport(from: try writeExport(rows))

        XCTAssertEqual(store.recordCountsByApp, ["com.microsoft.Outlook": 3, "net.whatsapp.WhatsApp": 1])

        store.deleteRecords(forBundleIdentifier: "com.microsoft.Outlook")

        XCTAssertEqual(store.recordCountsByApp, ["net.whatsapp.WhatsApp": 1])
        XCTAssertEqual(store.recordCount, 1)
    }

}
