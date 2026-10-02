import CoreGraphics
import XCTest
@testable import Cotabby

final class TranslationLanguagePolicyTests: XCTestCase {
    func test_turkishMessageNeedsTranslationIntoEnglish() {
        let detection = TranslationLanguagePolicy.needsTranslation(
            "Yarın sabah toplantıdan sonra seni arayacağım, tamam mı?", readingLanguage: "en"
        )
        XCTAssertEqual(detection?.language, "tr")
    }

    func test_englishMessageIsLeftAlone() {
        XCTAssertNil(TranslationLanguagePolicy.needsTranslation(
            "I will call you tomorrow morning after the meeting.", readingLanguage: "en-US"
        ))
    }

    func test_macedonianIsRecognizedByItsAlphabet() {
        XCTAssertEqual(TranslationLanguagePolicy.detect("Ќе ти се јавам после состанокот утре.")?.language, "mk")
    }

    func test_russianIsNotMistakenForMacedonian() {
        XCTAssertEqual(TranslationLanguagePolicy.detect("Я позвоню тебе завтра утром после встречи.")?.language, "ru")
    }

    func test_shortTextLinksAndNumbersAreSkipped() {
        XCTAssertNil(TranslationLanguagePolicy.detect("tamam"))
        XCTAssertNil(TranslationLanguagePolicy.detect("https://imperum.io/docs/getting-started"))
        XCTAssertNil(TranslationLanguagePolicy.detect("+31 6 1234 5678 / 11:20 / €4.500,00"))
    }

    func test_lowConfidenceHypothesesAreRejected() {
        XCTAssertNil(TranslationLanguagePolicy.confidentLanguage(from: [("tr", 0.55), ("az", 0.4)]))
        XCTAssertEqual(TranslationLanguagePolicy.confidentLanguage(from: [("tr", 0.92)])?.language, "tr")
    }

    func test_draftLanguageCheck() {
        XCTAssertTrue(TranslationLanguagePolicy.isWritten(in: "en", "Thanks, I will send the report tonight."))
        XCTAssertFalse(TranslationLanguagePolicy.isWritten(in: "en", "Teşekkürler, raporu bu akşam göndereceğim."))
    }
}

final class TranslationCacheTests: XCTestCase {
    private func result(_ text: String) -> TranslationResult {
        TranslationResult(sourceText: text, sourceLanguage: "tr", targetLanguage: "en", translatedText: text.uppercased())
    }

    func test_storesAndEvictsLeastRecentlyUsed() {
        var cache = TranslationCache(capacity: 2)
        cache.store(result("bir"))
        cache.store(result("iki"))
        _ = cache.value(for: "bir", target: "en")
        cache.store(result("üç"))

        XCTAssertNotNil(cache.value(for: "bir", target: "en"))
        XCTAssertNil(cache.value(for: "iki", target: "en"))
        XCTAssertEqual(cache.count, 2)
    }
}

final class FewShotTranslationPromptTests: XCTestCase {
    func test_promptEndsWithTheTargetLabelAndKeepsOneLinePerMessage() throws {
        let prompt = try XCTUnwrap(FewShotTranslationPrompt.prompt(for: "Здраво,\nкако си?", source: "mk", target: "en"))

        XCTAssertTrue(prompt.hasSuffix("Macedonian: Здраво, како си?\nEnglish:"))
        XCTAssertTrue(prompt.contains("English: I will call you after the meeting."))
    }

    func test_outputStopsAtTheFirstLineOrRepeatedLabel() {
        XCTAssertEqual(FewShotTranslationPrompt.cleanedOutput(" Hello, how are you?\n\nMacedonian: ..."), "Hello, how are you?")
        XCTAssertEqual(FewShotTranslationPrompt.cleanedOutput(" Hello there. Macedonian: Здраво"), "Hello there.")
    }

    func test_unsupportedPairsHaveNoPrompt() {
        XCTAssertFalse(FewShotTranslationPrompt.supports(source: "ja", target: "en"))
        XCTAssertNil(FewShotTranslationPrompt.prompt(for: "こんにちは", source: "ja", target: "en"))
    }
}

final class MessageBlockGrouperTests: XCTestCase {
    private let window = CGRect(x: 100, y: 100, width: 1000, height: 800)

    /// A Vision box for a line at the given window-relative top-left point.
    private func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat = 400, height: CGFloat = 20,
                      confidence: Float = 0.95) -> MessageBlockGrouper.Line {
        MessageBlockGrouper.Line(
            text: text, confidence: confidence,
            boundingBox: CGRect(x: x / 1000, y: 1 - (y + height) / 800, width: width / 1000, height: height / 800)
        )
    }

    func test_wrappedLinesOfOneMessageMergeAndSeparateMessagesStaySplit() {
        let lines = [
            line("Yarın sabah toplantıdan sonra", x: 400, y: 200),
            line("seni arayacağım.", x: 400, y: 222),
            line("Tamam, bekliyorum o zaman!", x: 400, y: 300)
        ]

        let blocks = MessageBlockGrouper.blocks(from: lines, windowFrame: window, composeFrame: nil)

        XCTAssertEqual(blocks.map(\.text), ["Yarın sabah toplantıdan sonra seni arayacağım.", "Tamam, bekliyorum o zaman!"])
        XCTAssertEqual(blocks[0].frame.minY, 300, accuracy: 0.5, "Mapped into global points")
    }

    func test_chatListLeftOfTheReplyFieldAndTheDraftAreIgnored() {
        let compose = CGRect(x: 400, y: 820, width: 600, height: 40)
        let lines = [
            line("Ahmet: Merhaba nasılsın bugün", x: 20, y: 200),
            line("Merhaba, toplantı saat kaçta?", x: 420, y: 200),
            line("draft I am typing right now", x: 320, y: 725)
        ]

        let blocks = MessageBlockGrouper.blocks(from: lines, windowFrame: window, composeFrame: compose)

        XCTAssertEqual(blocks.map(\.text), ["Merhaba, toplantı saat kaçta?"])
    }

    func test_timestampsAndLowConfidenceLinesAreDropped() {
        let lines = [
            line("11:20", x: 400, y: 200, width: 40),
            line("Iİ!", x: 400, y: 260, confidence: 0.2),
            line("Görüşürüz yarın akşam", x: 400, y: 320)
        ]

        XCTAssertEqual(MessageBlockGrouper.blocks(from: lines, windowFrame: window, composeFrame: nil).map(\.text),
                       ["Görüşürüz yarın akşam"])
    }
}

final class ConversationLanguageTrackerTests: XCTestCase {
    func test_remembersTheLatestLanguagePerConversationAndCaps() {
        var tracker = ConversationLanguageTracker(capacity: 2)
        let ahmet = ConversationLanguageTracker.key(bundleIdentifier: "net.whatsapp.WhatsApp", windowTitle: "Ahmet")
        tracker.record(language: "tr", for: ahmet, at: Date(timeIntervalSince1970: 1))
        tracker.record(language: "mk", for: "b", at: Date(timeIntervalSince1970: 2))
        tracker.record(language: "de", for: "c", at: Date(timeIntervalSince1970: 3))

        XCTAssertNil(tracker.language(for: ahmet), "The oldest conversation was evicted")
        XCTAssertEqual(tracker.language(for: "c"), "de")
    }
}

@MainActor
final class TranslationServiceTests: XCTestCase {
    private static var retained: [AnyObject] = []

    private final class FakeEngine: TranslationEngine {
        var status: TranslationPairAvailability
        private(set) var calls = 0
        let prefix: String
        init(status: TranslationPairAvailability, prefix: String) { self.status = status; self.prefix = prefix }
        func availability(from source: String, to target: String) async -> TranslationPairAvailability { status }
        func translate(_ text: String, from source: String, to target: String) async throws -> String {
            calls += 1
            return "\(prefix):\(text)"
        }
    }

    private func make(apple: TranslationPairAvailability, local: TranslationPairAvailability)
        -> (TranslationService, FakeEngine, FakeEngine) {
        let appleEngine = FakeEngine(status: apple, prefix: "apple")
        let localEngine = FakeEngine(status: local, prefix: "local")
        let service = TranslationService(apple: appleEngine, local: localEngine)
        Self.retained.append(contentsOf: [appleEngine, localEngine, service] as [AnyObject])
        return (service, appleEngine, localEngine)
    }

    func test_appleIsUsedWhenItHasThePair() async throws {
        let (service, apple, _) = make(apple: .ready, local: .localModel)

        let result = try await service.translate("Merhaba dünya", from: "tr", to: "en")

        XCTAssertEqual(result.translatedText, "apple:Merhaba dünya")
        _ = try await service.translate("Merhaba dünya", from: "tr", to: "en")
        XCTAssertEqual(apple.calls, 1, "The second request comes from the cache")
    }

    func test_localModelCoversPairsAppleDoesNotSupport() async throws {
        let (service, _, local) = make(apple: .unavailable, local: .localModel)

        let result = try await service.translate("Здраво", from: "mk", to: "en")

        XCTAssertEqual(result.translatedText, "local:Здраво")
        XCTAssertEqual(local.calls, 1)
        let status = await service.availability(from: "mk", to: "en")
        XCTAssertEqual(status, .localModel)
    }
}

@MainActor
final class TranslationPreferencesStoreTests: XCTestCase {
    private static var retained: [AnyObject] = []

    func test_defaultsAreOffWithSuggestedAppsAndPersist() {
        let suite = "cotabby.test.translation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TranslationPreferencesStore(userDefaults: defaults)
        Self.retained.append(store)
        XCTAssertFalse(store.preferences.isEnabled)
        XCTAssertTrue(store.preferences.appBundleIdentifiers.contains("net.whatsapp.WhatsApp"))
        XCTAssertFalse(store.isActive(forBundleIdentifier: "net.whatsapp.WhatsApp"), "Off until enabled")

        store.setEnabled(true)
        store.setReadingLanguage("tr")
        store.setApp("com.example.Chat", included: true)

        let reloaded = TranslationPreferencesStore(userDefaults: defaults)
        Self.retained.append(reloaded)
        XCTAssertTrue(reloaded.isActive(forBundleIdentifier: "com.example.Chat"))
        XCTAssertEqual(reloaded.preferences.readingLanguage, "tr")
    }
}
