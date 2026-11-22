import CryptoKit
import XCTest
@testable import Cotabby

/// Keeps vault keys in memory so tests never touch the developer's login Keychain.
private final class InMemoryKeyStore: TypingHistoryKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    private var deletionFails = false

    var hasKey: Bool { lock.withLock { key != nil } }

    /// Makes `deleteKey()` fail, the way a locked or denied Keychain would.
    func setDeletionFails(_ fails: Bool) { lock.withLock { deletionFails = fails } }

    func existingKey() throws -> SymmetricKey? { lock.withLock { key } }
    func createKey() throws -> SymmetricKey {
        lock.withLock {
            let created = SymmetricKey(size: .bits256)
            key = created
            return created
        }
    }
    func deleteKey() throws {
        try lock.withLock {
            if deletionFails { throw TypingHistoryVault.VaultError.keychain(errSecInteractionNotAllowed) }
            key = nil
        }
    }
}

/// Holds the first key lookup, which happens inside the first archive write, until released, so a
/// test can quit while a background save is still writing. Counts lookups, one per write.
private final class GatedKeyStore: TypingHistoryKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var key: SymmetricKey?
    private var lookups = 0
    private var holding = false

    var keyLookups: Int { lock.withLock { lookups } }
    var isHoldingAWrite: Bool { lock.withLock { holding } }
    func release() { gate.signal() }

    func existingKey() throws -> SymmetricKey? {
        let isFirst = lock.withLock {
            lookups += 1
            holding = lookups == 1
            return holding
        }
        if isFirst {
            gate.wait()
            lock.withLock { holding = false }
        }
        return lock.withLock { key }
    }
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

    // MARK: - Review fixes

    func test_aSaveCapturedBeforeDeleteAllIsNeverWritten() throws {
        let vault = makeVault()
        let writer = TypingHistoryWriter(vault: vault)
        let record = TypingHistoryRecord(
            id: UUID(), bundleIdentifier: "com.apple.mail", domain: nil, createdAt: Date(), updatedAt: Date(),
            text: "Deleted history must stay deleted.", source: .recorded
        )

        try writer.destroy(generation: 1)
        try writer.save([record], generation: 0, sequence: 1)

        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.fileURL.path))
    }

    func test_anOlderSnapshotCannotOverwriteANewerOne() throws {
        let vault = makeVault()
        let writer = TypingHistoryWriter(vault: vault)
        func record(_ text: String) -> TypingHistoryRecord {
            TypingHistoryRecord(id: UUID(), bundleIdentifier: "a", domain: nil, createdAt: Date(), updatedAt: Date(),
                                text: text, source: .recorded)
        }

        try writer.save([record("newer snapshot text")], generation: 0, sequence: 2)
        try writer.save([record("older snapshot text")], generation: 0, sequence: 1)

        XCTAssertEqual(try vault.load().map(\.text), ["newer snapshot text"])
    }

    private func focus(_ text: String, element: String, sequence: UInt64, app: String = "com.apple.mail",
                       isIntegratedTerminal: Bool = false, windowTitle: String? = nil) -> FocusSnapshot {
        let input = CotabbyTestFixtures.focusedInputSnapshot(
            bundleIdentifier: app, elementIdentifier: element, precedingText: text,
            isIntegratedTerminal: isIntegratedTerminal, focusChangeSequence: sequence, windowTitle: windowTitle
        )
        return FocusSnapshot(applicationName: "Mail", bundleIdentifier: app, capability: .supported, context: input)
    }

    func test_returningToAFieldContinuesItsRecord() {
        let store = makeStore()
        store.setRecording(true)

        store.observe(focus("Hi Arnaud, the Imperum POC is ready", element: "body", sequence: 1)) { true }
        store.observe(focus("", element: "search", sequence: 2)) { true }
        store.observe(focus("Hi Arnaud, the Imperum POC is ready for review.", element: "body", sequence: 3)) { true }
        store.observe(focus("", element: "search", sequence: 4)) { true }

        XCTAssertEqual(store.recordCount, 1)
    }

    func test_aReusedElementWithDifferentTextStartsANewRecord() {
        let store = makeStore()
        store.setRecording(true)

        store.observe(focus("Hi Arnaud, the Imperum POC is ready for review.", element: "body", sequence: 1)) { true }
        store.observe(focus("", element: "other", sequence: 2)) { true }
        store.observe(focus("A completely different message about lunch plans today.", element: "body", sequence: 3)) { true }
        store.observe(focus("", element: "other", sequence: 4)) { true }

        XCTAssertEqual(store.recordCount, 2)
    }

    func test_terminalsAreNeverRecorded() {
        let store = makeStore()
        store.setRecording(true)

        store.observe(focus("export OPENAI_API_KEY and run the deploy script", element: "t", sequence: 1,
                            app: "com.googlecode.iterm2")) { true }
        store.observe(focus("git push origin main and then open the pull request", element: "vs", sequence: 2,
                            app: "com.microsoft.VSCode", isIntegratedTerminal: true)) { true }
        store.observe(focus("", element: "x", sequence: 3)) { true }

        XCTAssertEqual(store.recordCount, 0)
    }

    // MARK: - Storage lifecycle

    func test_quittingWithoutHistoryCreatesNoArchiveOrKey() {
        let keyStore = InMemoryKeyStore()
        let vault = makeVault(keyStore: keyStore)
        let store = makeStore(vault: vault)
        store.setRecording(true)
        store.observe(focus("short")) { true }

        store.flush()

        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.fileURL.path))
        XCTAssertFalse(keyStore.hasKey)
    }

    func test_quittingAfterDeleteAllDoesNotRecreateTheArchive() async throws {
        let keyStore = InMemoryKeyStore()
        let vault = makeVault(keyStore: keyStore)
        let store = makeStore(vault: vault)
        await store.importCotypistExport(from: try writeExport(signOffRows(count: 3)))
        store.flush()

        store.deleteAll()
        store.flush()

        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.fileURL.path))
        XCTAssertFalse(keyStore.hasKey)
    }

    func test_quittingWhileABackgroundSaveIsStillWritingWritesAgain() async {
        let keyStore = GatedKeyStore()
        let store = TypingHistoryStore(
            vault: TypingHistoryVault(fileURL: directory.appendingPathComponent("TypingHistory.sealed"), keyStore: keyStore),
            userDefaults: defaults, loadsArchive: false, saveDelayNanoseconds: 0
        )
        Self.retained.append(store)
        store.setRecording(true)
        store.observe(focus("Hi Arnaud, the Imperum POC is ready", element: "body", sequence: 1)) { true }
        store.observe(focus("Hi Arnaud, the Imperum POC is ready for review.", element: "body", sequence: 1)) { true }
        await waitUntil { keyStore.isHoldingAWrite }
        // The background write finishes only after the quit has started waiting for it.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { keyStore.release() }

        store.flush()

        XCTAssertEqual(keyStore.keyLookups, 2, "The quit must not trust a write that hasn't finished")
    }

    func test_aFailedDeleteAllKeepsShowingTheHistoryAndCanBeRetried() async throws {
        let keyStore = InMemoryKeyStore()
        let store = makeStore(vault: makeVault(keyStore: keyStore))
        await store.importCotypistExport(from: try writeExport(signOffRows(count: 3)))
        store.flush()
        keyStore.setDeletionFails(true)

        store.deleteAll()

        XCTAssertEqual(store.recordCount, 3, "Nothing was deleted, so nothing should look deleted")
        XCTAssertNotNil(store.deletionError)

        keyStore.setDeletionFails(false)
        store.deleteAll()

        XCTAssertEqual(store.recordCount, 0)
        XCTAssertNil(store.deletionError)
        XCTAssertFalse(keyStore.hasKey)
    }

    func test_excludingAnAppMidFieldAlsoDropsTheAlreadySavedPart() throws {
        let vault = makeVault()
        let store = makeStore(vault: vault)
        store.setRecording(true)
        store.observe(focus("a long private chat message in WhatsApp", app: "net.whatsapp.WhatsApp")) { true }
        store.flush()
        XCTAssertEqual(store.recordCount, 1, "Saving copies the field being typed in")

        store.setExcluded("net.whatsapp.WhatsApp", excluded: true)
        store.flush()

        XCTAssertEqual(store.recordCount, 0)
        XCTAssertEqual(try vault.load(), [])
    }

    // MARK: - Field identity

    private func storedTexts(_ store: TypingHistoryStore, vault: TypingHistoryVault) throws -> [String] {
        store.flush()
        return try vault.load().map(\.text).sorted()
    }

    func test_eachSentChatMessageIsKeptWhenTheComposerClears() throws {
        let vault = makeVault()
        let store = makeStore(vault: vault)
        store.setRecording(true)

        store.observe(focus("", element: "composer", sequence: 1)) { true }
        store.observe(focus("Hey, are we still on for lunch tomorrow?", element: "composer", sequence: 1)) { true }
        store.observe(focus("", element: "composer", sequence: 1)) { true }
        store.observe(focus("Great, I will book the usual place at noon.", element: "composer", sequence: 1)) { true }
        store.observe(focus("", element: "composer", sequence: 1)) { true }
        store.observe(focus("", element: "search", sequence: 2)) { true }

        XCTAssertEqual(try storedTexts(store, vault: vault), [
            "Great, I will book the usual place at noon.",
            "Hey, are we still on for lunch tomorrow?"
        ])
    }

    func test_anEmptyFieldReusingAnElementNeverOverwritesEarlierWriting() throws {
        let vault = makeVault()
        let store = makeStore(vault: vault)
        store.setRecording(true)

        store.observe(focus("Hi Arnaud, the Imperum POC is ready for review.", element: "body", sequence: 1)) { true }
        store.observe(focus("", element: "other", sequence: 2)) { true }
        // A new compose window that got the old body's element identifier, empty at first.
        store.observe(focus("", element: "body", sequence: 3)) { true }
        store.observe(focus("Lunch at noon tomorrow works for me, see you.", element: "body", sequence: 3)) { true }
        store.observe(focus("", element: "other", sequence: 4)) { true }

        XCTAssertEqual(try storedTexts(store, vault: vault), [
            "Hi Arnaud, the Imperum POC is ready for review.",
            "Lunch at noon tomorrow works for me, see you."
        ])
    }

    func test_aFieldThatBrieflyReadsEmptyKeepsOneRecord() throws {
        let vault = makeVault()
        let store = makeStore(vault: vault)
        store.setRecording(true)

        store.observe(focus("Hi Arnaud, the Imperum POC is ready", element: "body", sequence: 1)) { true }
        store.observe(focus("", element: "body", sequence: 1)) { true }
        store.observe(focus("Hi Arnaud, the Imperum POC is ready for review.", element: "body", sequence: 1)) { true }
        store.observe(focus("", element: "other", sequence: 2)) { true }

        XCTAssertEqual(try storedTexts(store, vault: vault), ["Hi Arnaud, the Imperum POC is ready for review."])
    }

    func test_deletingAFieldsTextKeyByKeyStillDiscardsIt() {
        let store = makeStore()
        store.setRecording(true)
        let text = "Hi Arnaud, the Imperum POC is ready for review."
        store.observe(focus(text, element: "body", sequence: 1)) { true }
        store.flush()
        XCTAssertEqual(store.recordCount, 1)

        for length in stride(from: text.count - 1, through: 0, by: -1) {
            store.observe(focus(String(text.prefix(length)), element: "body", sequence: 1)) { true }
        }
        store.observe(focus("", element: "other", sequence: 2)) { true }

        XCTAssertEqual(store.recordCount, 0)
    }

    func test_aLongDocumentsSlidingCaptureWindowStaysOneRecord() {
        let store = makeStore()
        store.setRecording(true)
        // Focus capture keeps a fixed window before the caret, so in a long document every
        // keystroke drops a character from the front of the window as it adds one at the caret.
        let document = (0..<1_000).map { "word\($0)" }.joined(separator: " ")
        var window = String(document.suffix(FocusedInputSnapshot.textWindowUTF16))
        store.observe(focus(window, element: "doc", sequence: 1)) { true }
        for character in " and a few more words typed at the end" {
            window = String((window + String(character)).suffix(FocusedInputSnapshot.textWindowUTF16))
            store.observe(focus(window, element: "doc", sequence: 1)) { true }
        }
        store.observe(focus("", element: "other", sequence: 2)) { true }

        XCTAssertEqual(store.recordCount, 1)
    }

    func test_anotherLongDocumentShownInTheSameViewKeepsBothRecords() {
        let store = makeStore()
        store.setRecording(true)
        let window = FocusedInputSnapshot.textWindowUTF16
        let first = String((0..<1_000).map { "alpha\($0)" }.joined(separator: " ").suffix(window))
        let second = String((0..<1_000).map { "beta\($0)" }.joined(separator: " ").suffix(window))

        store.observe(focus(first, element: "doc", sequence: 1, windowTitle: "First.txt")) { true }
        store.observe(focus(second, element: "doc", sequence: 1, windowTitle: "Second.txt")) { true }
        store.observe(focus("", element: "other", sequence: 2)) { true }

        XCTAssertEqual(store.recordCount, 2)
    }

    func test_aCaretJumpInALongDocumentKeepsOneRecord() {
        let store = makeStore()
        store.setRecording(true)
        let window = FocusedInputSnapshot.textWindowUTF16
        let document = (0..<2_000).map { "word\($0)" }.joined(separator: " ")
        let nearEnd = String(document.suffix(window))
        let nearMiddle = String(document.prefix(document.count / 2).suffix(window))

        store.observe(focus(nearEnd, element: "doc", sequence: 1, windowTitle: "Notes.txt")) { true }
        store.observe(focus(nearMiddle, element: "doc", sequence: 1, windowTitle: "Notes.txt")) { true }
        store.observe(focus("", element: "other", sequence: 2)) { true }

        XCTAssertEqual(store.recordCount, 1)
    }

    func test_sharesContentFollowsASlidingWindowButNotAnotherDocument() {
        let window = FocusedInputSnapshot.textWindowUTF16
        let current = String((0..<1_000).map { "word\($0)" }.joined(separator: " ").suffix(window))

        XCTAssertTrue(TypingHistoryStore.sharesContent(current, with: String((current + " and more").suffix(window))))
        XCTAssertFalse(TypingHistoryStore.sharesContent(
            current, with: String((0..<1_000).map { "other\($0)" }.joined(separator: " ").suffix(window))
        ))
    }

    func test_keepsMostOfTellsEditsFromReplacements() {
        let draft = "Hi Arnaud, the Imperum POC is ready for review."

        XCTAssertTrue(TypingHistoryStore.keepsMostOf(draft, in: draft + " Thanks"), "Typing at the end")
        XCTAssertTrue(TypingHistoryStore.keepsMostOf(draft, in: "Hello Arnaud, the Imperum POC is ready for review."),
                      "Fixing the first word")
        XCTAssertTrue(TypingHistoryStore.keepsMostOf(draft, in: String(draft.dropLast(5))), "Deleting a few characters")
        XCTAssertFalse(TypingHistoryStore.keepsMostOf(draft, in: ""), "A sent message cleared from the composer")
        XCTAssertFalse(TypingHistoryStore.keepsMostOf(draft, in: "Lunch at noon tomorrow works for me."), "Different text")
    }

    // MARK: - Example cache

    func test_cachedExamplesAreRecheckedAsTheFieldGrowsWithinABlock() async throws {
        let store = makeStore()
        store.setUsingHistory(true)
        await store.importCotypistExport(from: try writeExport([[
            "appBundleIdentifier": "com.example.TestApp",
            "textUpToCursor": "we will review the Imperum connector plan with the SOC team on Monday morning, then ship it."
        ]]))
        // 16 words: the query block for both lookups below.
        let opening = "Draft notes for Friday about unrelated budget items we will review the Imperum connector plan with "
        let earlier = CotabbyTestFixtures.focusedInputContext(precedingText: opening)
        // Five more words, still inside the same 8-word block, and now the field holds the past text.
        let later = CotabbyTestFixtures.focusedInputContext(precedingText: opening + "the SOC team on Monday")
        XCTAssertEqual(
            TypingHistoryQuery.stableText(from: earlier.precedingText),
            TypingHistoryQuery.stableText(from: later.precedingText)
        )

        await waitUntil { !store.historyExamples(for: earlier, engine: .llamaOpenSource).isEmpty }

        XCTAssertEqual(store.historyExamples(for: later, engine: .llamaOpenSource), [],
                       "The field now contains that writing; showing it would make the model echo the draft")
    }

    func test_anExampleHiddenByTheFieldsLatestWordsComesBackWhenTheWordingMovesOn() async throws {
        let store = makeStore()
        store.setUsingHistory(true)
        let earlier = "we will review the Imperum connector plan with the SOC team on Monday morning, then ship it."
        await store.importCotypistExport(from: try writeExport([[
            "appBundleIdentifier": "com.example.TestApp", "textUpToCursor": earlier
        ]]))
        let probe = CotabbyTestFixtures.focusedInputContext(
            elementIdentifier: "probe", precedingText: "Imperum connector plan review notes for the steering group "
        )
        await waitUntil { !store.historyExamples(for: probe, engine: .llamaOpenSource).isEmpty }
        // The field's latest words are inside the earlier passage, so it is withheld for now.
        let echoing = "Budget notes for Friday and several other items: please review the Imperum connector plan with "
            + "the SOC team on Monday"
        XCTAssertEqual(
            store.historyExamples(for: CotabbyTestFixtures.focusedInputContext(precedingText: echoing), engine: .llamaOpenSource), []
        )

        // Two more words, same 8-word block: the wording has moved on, so the passage is usable again.
        let movedOn = CotabbyTestFixtures.focusedInputContext(precedingText: echoing + " evening instead")
        XCTAssertEqual(
            TypingHistoryQuery.stableText(from: echoing), TypingHistoryQuery.stableText(from: movedOn.precedingText)
        )
        XCTAssertFalse(store.historyExamples(for: movedOn, engine: .llamaOpenSource).isEmpty)
    }

    func test_unchangedTextDoesNotEvaluateTheSettingsGate() {
        let store = makeStore()
        store.setRecording(true)
        var gateCalls = 0

        store.observe(focus("Hi Arnaud, the Imperum POC is ready", element: "body", sequence: 1)) { gateCalls += 1; return true }
        store.observe(focus("Hi Arnaud, the Imperum POC is ready", element: "body", sequence: 1)) { gateCalls += 1; return true }

        XCTAssertEqual(gateCalls, 1)
    }

}
