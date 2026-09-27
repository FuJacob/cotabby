import CoreGraphics
import XCTest
// `@preconcurrency`: see `InlineFeatureTestDoubles.swift`.
@preconcurrency @testable import Cotabby

/// Pins how `InlineCommandCoordinator` shares the input monitor's two single slots between the emoji
/// picker and the macro preview: the capture-interception flag must track "either feature is
/// capturing" (including teardown that happens outside a keystroke), and the one accept-tap decider
/// must route each key to whichever capture claimed it. Both controllers are real; only their OS
/// seams are faked.
@MainActor
final class InlineCommandCoordinatorTests: XCTestCase {
    private var rigs: [Rig] = []

    override func tearDown() {
        rigs.removeAll()
        super.tearDown()
    }

    private func makeRig() -> Rig {
        let rig = Rig()
        rig.coordinator.start()
        rigs.append(rig)
        return rig
    }

    func test_startInstallsDeciderAndOrdinaryTypingIsNotClaimed() {
        let rig = makeRig()
        XCTAssertNotNil(rig.monitor.emojiCaptureKeyDecider)

        XCTAssertFalse(rig.type("hi"))
        XCTAssertEqual(rig.decide(InlineFeatureKeys.characterKeyCode), .notHandled)
        XCTAssertEqual(rig.monitor.captureActiveCalls.last, false)
    }

    func test_emojiCaptureRaisesInterceptionAndOwnsTheAcceptKey() {
        let rig = makeRig()

        XCTAssertTrue(rig.type(":smile"))
        XCTAssertEqual(rig.monitor.captureActiveCalls.last, true)

        XCTAssertTrue(rig.coordinator.observe(InlineFeatureKeys.key(InlineFeatureKeys.tab)))
        XCTAssertEqual(rig.decide(InlineFeatureKeys.tab), .consume)
        XCTAssertEqual(rig.monitor.captureActiveCalls.last, false, "Commit closes the only capture")

        drainInlineFeatureMainQueue()
        XCTAssertEqual(rig.inserter.calls, [.init(deleteCount: 6, text: "😄")])
    }

    func test_macroCaptureRaisesInterceptionAndOwnsTheAcceptKey() {
        let rig = makeRig()

        XCTAssertTrue(rig.type("/2+2"))
        XCTAssertEqual(rig.monitor.captureActiveCalls.last, true)

        XCTAssertTrue(rig.coordinator.observe(InlineFeatureKeys.key(InlineFeatureKeys.tab)))
        XCTAssertEqual(rig.decide(InlineFeatureKeys.tab), .consume)
        XCTAssertEqual(rig.monitor.captureActiveCalls.last, false)

        drainInlineFeatureMainQueue()
        XCTAssertEqual(rig.inserter.calls, [.init(deleteCount: 4, text: "4")])
    }

    func test_teardownOutsideAKeystrokeDropsInterception() {
        let rig = makeRig()
        rig.type(":smi")
        XCTAssertEqual(rig.monitor.captureActiveCalls.last, true)

        // A focus change cancels the capture from the focus sink, not from `observe`, so only the
        // controller's capture-state callback can tell the coordinator to drop interception.
        rig.focus.publish(focusChangeSequence: 2)

        XCTAssertEqual(rig.monitor.captureActiveCalls.last, false)
    }

    func test_stopClearsDeciderAndInterception() {
        let rig = makeRig()
        rig.type(":smi")

        rig.coordinator.stop()

        XCTAssertNil(rig.monitor.emojiCaptureKeyDecider)
        XCTAssertEqual(rig.monitor.captureActiveCalls.last, false)
    }

    // MARK: - Rig

    @MainActor
    private final class Rig {
        let focus: InlineFeatureFocusStub
        let monitor: InlineFeatureInputMonitorStub
        let inserter: InlineFeatureRecordingInserter
        let coordinator: InlineCommandCoordinator

        init() {
            // Locals first: `self` cannot be read until every stored property is initialized.
            let focus = InlineFeatureFocusStub(precedingText: ":smile")
            let monitor = InlineFeatureInputMonitorStub()
            let inserter = InlineFeatureRecordingInserter()
            self.focus = focus
            self.monitor = monitor
            self.inserter = inserter
            let catalog = EmojiCatalog(entries: [
                EmojiEntry(glyph: "😄", name: "smiling face", aliases: ["smile"], keywords: [])
            ])
            let emoji = EmojiPickerController(
                matcherProvider: { EmojiMatcher(catalog: catalog) },
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
                engine: MacroEngine(evaluators: [
                    InlineFeatureMacroTable(results: ["2+2": MacroResult("4")])
                ]),
                panel: InlineFeaturePreviewPanelStub(),
                focusModel: focus,
                inserter: inserter,
                isEnabled: { true },
                acceptKeyLabel: { nil },
                isWordAcceptKey: { $0.keyCode == InlineFeatureKeys.tab }
            )
            coordinator = InlineCommandCoordinator(emoji: emoji, macro: macro, inputMonitor: monitor)
        }

        /// Feeds each character through the coordinator; true if any keystroke involved a feature.
        @discardableResult
        func type(_ text: String) -> Bool {
            var involved = false
            for character in text {
                if coordinator.observe(InlineFeatureKeys.character(character)) {
                    involved = true
                }
            }
            return involved
        }

        func decide(_ keyCode: CGKeyCode) -> InputMonitorAcceptTapDecision? {
            monitor.emojiCaptureKeyDecider?(InlineFeatureKeys.tapEvent(keyCode))
        }
    }
}
