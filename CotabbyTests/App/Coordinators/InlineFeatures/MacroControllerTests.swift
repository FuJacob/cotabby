import CoreGraphics
import XCTest
// `@preconcurrency`: see `InlineFeatureTestDoubles.swift`.
@preconcurrency @testable import Cotabby

/// Composition tests for the inline `/macro` preview. `MacroTriggerStateMachine` and the evaluators
/// have their own suites; these pin the controller seam around them: when the preview shows or hides,
/// that accept replaces exactly the tracked `/query` run on the next run-loop tick, which keys are
/// consumed versus passed through (arrows end capture here, unlike the emoji ribbon), and that focus
/// changes, secure fields, and disabling tear the capture down.
@MainActor
final class MacroControllerTests: XCTestCase {
    /// Retained for the whole test so the controller's `[weak self]` deferred replace still has a
    /// target when the main queue is drained.
    private var harnesses: [Harness] = []

    override func tearDown() {
        harnesses.removeAll()
        super.tearDown()
    }

    private func makeHarness(isSecure: Bool = false, acceptKeyLabel: String? = "Tab") -> Harness {
        let harness = Harness(isSecure: isSecure, acceptKeyLabel: acceptKeyLabel)
        harnesses.append(harness)
        return harness
    }

    // MARK: - Preview

    func test_openingSlashCapturesButShowsNothingUntilAQueryEvaluates() {
        let harness = makeHarness()

        XCTAssertTrue(harness.controller.observe(InlineFeatureKeys.character("/")))

        XCTAssertTrue(harness.controller.isCapturing)
        XCTAssertTrue(harness.panel.presentations.isEmpty)
        XCTAssertEqual(harness.captureStateChanges, 1)
    }

    func test_evaluatingQueryShowsPreviewAtCaretWithAcceptLabel() {
        let harness = makeHarness(acceptKeyLabel: "⇥")

        harness.type("/2+2")

        XCTAssertEqual(
            harness.panel.presentations.last,
            .init(previewText: "= 4", caretRect: Harness.caretRect, acceptKeyLabel: "⇥")
        )
        XCTAssertTrue(harness.panel.isVisible)
    }

    func test_queryWithNoResultHidesPreviewButKeepsCapturing() {
        let harness = makeHarness()
        harness.type("/2+2")

        harness.controller.observe(InlineFeatureKeys.key(InlineFeatureKeys.backspace))   // "2+"

        XCTAssertTrue(harness.controller.isCapturing)
        XCTAssertFalse(harness.panel.isVisible)
    }

    // MARK: - Commit

    func test_acceptKeyIsConsumedAndReplacesTrackedRunOnNextTick() {
        let harness = makeHarness()
        harness.type("/2+2")

        XCTAssertTrue(harness.controller.observe(InlineFeatureKeys.key(InlineFeatureKeys.tab)))
        XCTAssertEqual(harness.controller.decideCaptureKey(InlineFeatureKeys.tapEvent(InlineFeatureKeys.tab)), .consume)
        XCTAssertTrue(harness.inserter.calls.isEmpty, "The replace must be deferred off the tap callback.")
        XCTAssertFalse(harness.panel.isVisible)
        XCTAssertFalse(harness.controller.isCapturing)

        drainInlineFeatureMainQueue()

        // Deletes "/" + "2+2" and inserts the result's insertion text, not its preview text.
        XCTAssertEqual(harness.inserter.calls, [.init(deleteCount: 4, text: "2+2=4")])
        XCTAssertEqual(harness.focus.refreshCount, 1)
    }

    func test_panelClickCommitsCurrentResult() {
        let harness = makeHarness()
        harness.type("/2+2")

        harness.panel.onClick?()
        drainInlineFeatureMainQueue()

        XCTAssertEqual(harness.inserter.calls, [.init(deleteCount: 4, text: "2+2=4")])
    }

    func test_acceptKeyWithoutResultPassesThroughAndCancels() {
        let harness = makeHarness()
        harness.type("/2+")

        harness.controller.observe(InlineFeatureKeys.key(InlineFeatureKeys.tab))
        XCTAssertEqual(harness.controller.decideCaptureKey(InlineFeatureKeys.tapEvent(InlineFeatureKeys.tab)), .passThrough)
        drainInlineFeatureMainQueue()

        XCTAssertTrue(harness.inserter.calls.isEmpty)
        XCTAssertFalse(harness.controller.isCapturing)
    }

    func test_rebindingAcceptKeyIsHonoredForCommit() {
        let harness = makeHarness()
        harness.wordAcceptKeyCode = 50
        harness.type("/2+2")

        harness.controller.observe(InlineFeatureKeys.key(InlineFeatureKeys.tab))
        XCTAssertEqual(
            harness.controller.decideCaptureKey(InlineFeatureKeys.tapEvent(InlineFeatureKeys.tab)),
            .passThrough,
            "After the rebind Tab is an ordinary key, so it only dismisses the capture"
        )
        XCTAssertTrue(harness.inserter.calls.isEmpty)

        harness.type("/2+2")
        harness.controller.observe(InlineFeatureKeys.key(50))
        drainInlineFeatureMainQueue()

        XCTAssertEqual(harness.inserter.calls, [.init(deleteCount: 4, text: "2+2=4")])
    }

    // MARK: - Other keys

    func test_escapeIsConsumedAndCancels() {
        let harness = makeHarness()
        harness.type("/2+2")

        harness.controller.observe(InlineFeatureKeys.key(InlineFeatureKeys.escape))

        XCTAssertEqual(harness.controller.decideCaptureKey(InlineFeatureKeys.tapEvent(InlineFeatureKeys.escape)), .consume)
        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertFalse(harness.panel.isVisible)
    }

    func test_arrowsReturnAndModifiedKeysEndCaptureAndPassThrough() {
        let keys: [(name: String, event: CapturedInputEvent)] = [
            ("left", InlineFeatureKeys.key(InlineFeatureKeys.left)),
            ("right", InlineFeatureKeys.key(InlineFeatureKeys.right)),
            ("up", InlineFeatureKeys.key(InlineFeatureKeys.up)),
            ("down", InlineFeatureKeys.key(InlineFeatureKeys.down)),
            ("return", InlineFeatureKeys.key(InlineFeatureKeys.returnKey)),
            ("cmd+tab", InlineFeatureKeys.key(InlineFeatureKeys.tab, flags: .maskCommand)),
            ("option+backspace", InlineFeatureKeys.key(InlineFeatureKeys.backspace, flags: .maskAlternate))
        ]
        for key in keys {
            let harness = makeHarness()
            harness.type("/2+2")

            XCTAssertTrue(harness.controller.observe(key.event), key.name)
            XCTAssertEqual(
                harness.controller.decideCaptureKey(InlineFeatureKeys.tapEvent(key.event.keyCode)),
                .passThrough,
                key.name
            )
            XCTAssertFalse(harness.controller.isCapturing, key.name)
            drainInlineFeatureMainQueue()
            XCTAssertTrue(harness.inserter.calls.isEmpty, key.name)
        }
    }

    func test_whitespaceTerminatesCaptureLeavingLiteralText() {
        let harness = makeHarness()
        harness.type("/2+2 ")
        drainInlineFeatureMainQueue()

        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertFalse(harness.panel.isVisible)
        XCTAssertTrue(harness.inserter.calls.isEmpty)
    }

    // MARK: - Lifecycle and gating

    func test_secureFieldAbortsOpen() {
        let harness = makeHarness(isSecure: true)

        XCTAssertFalse(harness.controller.observe(InlineFeatureKeys.character("/")))
        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertEqual(harness.captureStateChanges, 0)
    }

    func test_disablingMidCaptureCancelsAndStandsDown() {
        let harness = makeHarness()
        harness.type("/2+2")

        harness.enabled = false

        XCTAssertFalse(harness.controller.observe(InlineFeatureKeys.key(InlineFeatureKeys.tab)))
        XCTAssertEqual(harness.controller.decideCaptureKey(InlineFeatureKeys.tapEvent(InlineFeatureKeys.tab)), .notHandled)
        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertFalse(harness.panel.isVisible)
    }

    func test_focusSnapshotForSameFieldMovesPreviewToNewCaret() {
        let harness = makeHarness()
        harness.type("/2+2")
        let movedCaret = CGRect(x: 120, y: 60, width: 2, height: 18)

        harness.focus.publish(focusChangeSequence: 1, caretRect: movedCaret)

        XCTAssertTrue(harness.controller.isCapturing)
        XCTAssertEqual(harness.panel.presentations.last?.caretRect, movedCaret)
    }

    func test_focusChangeOrSecureFieldDuringCaptureCancels() {
        let cases: [(name: String, sequence: UInt64, isSecure: Bool)] = [
            ("different field", 2, false),
            ("same field turned secure", 1, true)
        ]
        for testCase in cases {
            let harness = makeHarness()
            harness.type("/2+2")

            harness.focus.publish(isSecure: testCase.isSecure, focusChangeSequence: testCase.sequence)

            XCTAssertFalse(harness.controller.isCapturing, testCase.name)
            XCTAssertFalse(harness.panel.isVisible, testCase.name)
            XCTAssertEqual(harness.captureStateChanges, 2, "\(testCase.name): open + teardown")
        }
    }

    func test_clickOutsideCancelsAndStopIsQuietWhenIdle() {
        let harness = makeHarness()
        harness.type("/2+2")

        harness.panel.onClickOutside?()
        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertEqual(harness.captureStateChanges, 2)

        harness.controller.stop()
        XCTAssertEqual(harness.captureStateChanges, 2, "Stopping while idle must not report a change")
    }

    // MARK: - Harness

    @MainActor
    private final class Harness {
        static let caretRect = CGRect(x: 10, y: 20, width: 2, height: 18)

        let focus: InlineFeatureFocusStub
        let inserter: InlineFeatureRecordingInserter
        let panel: InlineFeaturePreviewPanelStub
        let controller: MacroController
        private let flags: MacroHarnessFlags
        private(set) var captureStateChanges = 0

        /// Both are read live by the controller's closures, so a test can flip them mid-capture.
        var enabled: Bool {
            get { flags.enabled }
            set { flags.enabled = newValue }
        }

        var wordAcceptKeyCode: CGKeyCode {
            get { flags.wordAcceptKeyCode }
            set { flags.wordAcceptKeyCode = newValue }
        }

        init(isSecure: Bool, acceptKeyLabel: String?) {
            // A fixed table keeps the evaluator out of the picture: only "2+2" has a result, and its
            // preview and insertion texts differ so tests can tell which one reached the field.
            let engine = MacroEngine(evaluators: [
                InlineFeatureMacroTable(results: [
                    "2+2": MacroResult(previewText: "= 4", insertionText: "2+2=4")
                ])
            ])
            let focus = InlineFeatureFocusStub(isSecure: isSecure, caretRect: Self.caretRect)
            let inserter = InlineFeatureRecordingInserter()
            let panel = InlineFeaturePreviewPanelStub()
            let flags = MacroHarnessFlags()
            self.focus = focus
            self.inserter = inserter
            self.panel = panel
            self.flags = flags
            controller = MacroController(
                engine: engine,
                panel: panel,
                focusModel: focus,
                inserter: inserter,
                isEnabled: { flags.enabled },
                acceptKeyLabel: { acceptKeyLabel },
                // Production wires this to the input monitor's binding check (Tab by default).
                isWordAcceptKey: { $0.keyCode == flags.wordAcceptKeyCode }
            )
            controller.onCaptureStateChanged = { [weak self] in self?.captureStateChanges += 1 }
            controller.start()
        }

        func type(_ text: String) {
            for character in text {
                controller.observe(InlineFeatureKeys.character(character))
            }
        }
    }
}

/// Mutable state read by the controller's plain (non-actor) `isEnabled` and `isWordAcceptKey`
/// closures, kept nonisolated to match those closure types.
private final class MacroHarnessFlags {
    var enabled = true
    var wordAcceptKeyCode: CGKeyCode = InlineFeatureKeys.tab
}
