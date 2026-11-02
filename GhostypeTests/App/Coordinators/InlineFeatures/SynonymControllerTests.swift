import CoreGraphics
import XCTest
// `@preconcurrency`: see `InlineFeatureTestDoubles.swift`.
@preconcurrency @testable import Ghostype

/// Composition tests for selected-word synonyms, through the real `InlineCommandCoordinator` so the
/// input monitor's decider and interception flag are exercised as production uses them. The OS seams
/// (focus, panel, inserter, monitor) and the engine are fakes; `SelectedWordSynonymsTests` covers the
/// pure rules.
@MainActor
final class SynonymControllerTests: XCTestCase {
    private var rigs: [Rig] = []

    override func tearDown() {
        rigs.removeAll()
        super.tearDown()
    }

    private func makeRig(disabledReason: String? = nil) -> Rig {
        let rig = Rig(disabledReason: disabledReason)
        rigs.append(rig)
        return rig
    }

    func test_selectingAWordShowsNumberedSynonymsAndRaisesInterception() {
        let rig = makeRig()
        rig.selectWord("happy")

        XCTAssertTrue(rig.waitForList())
        XCTAssertEqual(rig.panel.presentations.last?.previewText, "1 glad   2 cheerful   3 joyful")
        XCTAssertEqual(rig.monitor.captureActiveCalls.last, true)
        XCTAssertEqual(rig.engine.requests.count, 1)
        XCTAssertTrue(rig.engine.requests[0].prompt.hasSuffix("Synonyms for happy:"))
    }

    func test_digitIsConsumedAndTypesTheChoiceOverTheSelection() {
        let rig = makeRig()
        rig.selectWord("happy")
        XCTAssertTrue(rig.waitForList())

        XCTAssertTrue(rig.coordinator.observe(InlineFeatureKeys.character("2")))
        XCTAssertEqual(rig.decide(InlineFeatureKeys.characterKeyCode), .consume)
        XCTAssertFalse(rig.panel.isVisible)
        XCTAssertEqual(rig.monitor.captureActiveCalls.last, false)

        drainInlineFeatureMainQueue()
        XCTAssertEqual(rig.inserter.calls, [.init(deleteCount: 0, text: "cheerful")])
    }

    func test_digitsAreNeverClaimedWithoutAList() {
        let rig = makeRig()

        XCTAssertFalse(rig.coordinator.observe(InlineFeatureKeys.character("1")))
        XCTAssertEqual(rig.decide(InlineFeatureKeys.characterKeyCode), .notHandled)
        XCTAssertNotEqual(rig.monitor.captureActiveCalls.last, true)
    }

    func test_otherKeyDismissesAndPassesThroughWhileEscapeIsSwallowed() {
        let rig = makeRig()
        rig.selectWord("happy")
        XCTAssertTrue(rig.waitForList())

        XCTAssertFalse(rig.coordinator.observe(InlineFeatureKeys.character("x")))
        XCTAssertEqual(rig.decide(InlineFeatureKeys.characterKeyCode), .passThrough)
        XCTAssertFalse(rig.panel.isVisible)

        // Re-select so a fresh list opens, then Esc it.
        rig.focus.publish(focusChangeSequence: 1)
        rig.selectWord("happy")
        XCTAssertTrue(rig.waitForList())
        XCTAssertTrue(rig.coordinator.observe(InlineFeatureKeys.key(InlineFeatureKeys.escape)))
        XCTAssertEqual(rig.decide(InlineFeatureKeys.escape), .consume)
        drainInlineFeatureMainQueue()
        XCTAssertTrue(rig.inserter.calls.isEmpty)
    }

    func test_selectionChangeDismissesTheList() {
        let rig = makeRig()
        rig.selectWord("happy")
        XCTAssertTrue(rig.waitForList())

        rig.focus.publish(focusChangeSequence: 1)

        XCTAssertFalse(rig.panel.isVisible)
        XCTAssertEqual(rig.monitor.captureActiveCalls.last, false)
    }

    func test_disabledFieldOrPhraseSelectionAsksNothing() {
        let off = makeRig(disabledReason: "Ghostype is disabled in TestApp.")
        off.selectWord("happy")
        let phrase = makeRig()
        phrase.selectWord("very happy")

        XCTAssertFalse(off.waitForList(timeout: 0.6))
        XCTAssertFalse(phrase.waitForList(timeout: 0.1))
        XCTAssertTrue(off.engine.requests.isEmpty)
        XCTAssertTrue(phrase.engine.requests.isEmpty)
    }

    // MARK: - Rig

    @MainActor
    private final class Rig {
        let focus: InlineFeatureFocusStub
        let monitor: InlineFeatureInputMonitorStub
        let inserter: InlineFeatureRecordingInserter
        let panel: InlineFeaturePreviewPanelStub
        let engine: RigSuggestionEngine
        let coordinator: InlineCommandCoordinator

        init(disabledReason: String?) {
            // Locals first: `self` cannot be read until every stored property is initialized.
            let focus = InlineFeatureFocusStub()
            let monitor = InlineFeatureInputMonitorStub()
            let inserter = InlineFeatureRecordingInserter()
            let panel = InlineFeaturePreviewPanelStub()
            let engine = RigSuggestionEngine()
            self.focus = focus
            self.monitor = monitor
            self.inserter = inserter
            self.panel = panel
            self.engine = engine
            engine.resultProvider = { request in
                SuggestionResult(generation: request.generation, rawText: "", text: " Glad, cheerful, joyful", latency: 0)
            }
            let emoji = EmojiPickerController(
                matcherProvider: { EmojiMatcher(catalog: EmojiCatalog(entries: [])) },
                panel: InlineFeatureEmojiPanelStub(),
                focusModel: focus,
                inputMonitor: monitor,
                inserter: inserter,
                isEnabled: { true },
                emojiPreferences: { EmojiVariantPreferences(skinTone: .neutral, gender: .neutral) },
                emojiUsage: { EmojiUsageSnapshot.empty },
                recordEmojiUsage: { _ in }
            )
            let macro = MacroController(
                engine: MacroEngine(evaluators: []),
                panel: InlineFeaturePreviewPanelStub(),
                focusModel: focus,
                inserter: inserter,
                isEnabled: { true },
                acceptKeyLabel: { nil },
                isWordAcceptKey: { $0.keyCode == InlineFeatureKeys.tab }
            )
            let synonyms = SynonymController(
                panel: panel,
                focusModel: focus,
                inserter: inserter,
                engine: engine,
                disabledReason: { _ in disabledReason }
            )
            coordinator = InlineCommandCoordinator(emoji: emoji, macro: macro, synonyms: synonyms, inputMonitor: monitor)
            coordinator.start()
        }

        func selectWord(_ text: String) {
            focus.publish(SelectedWordSynonymsTests.snapshot(selectedText: text))
        }

        /// Spins the run loop until the list shows (the controller waits `settleNanoseconds` before
        /// asking the engine) or the timeout passes.
        func waitForList(timeout: TimeInterval = 3) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !panel.isVisible, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return panel.isVisible
        }

        func decide(_ keyCode: CGKeyCode) -> InputMonitorAcceptTapDecision? {
            monitor.emojiCaptureKeyDecider?(InlineFeatureKeys.tapEvent(keyCode))
        }
    }
}
