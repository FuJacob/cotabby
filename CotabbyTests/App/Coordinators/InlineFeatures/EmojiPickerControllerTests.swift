import CoreGraphics
import XCTest
// `@preconcurrency`: see `InlineFeatureTestDoubles.swift`; the fakes conform to `@MainActor`
// protocols with non-`@Sendable` closure properties.
@preconcurrency @testable import Cotabby

/// Composition tests for the inline `:emoji:` picker. The pure trigger machine, matcher, and query-run
/// measurement are covered by their own suites; these lock down the controller <-> focus <-> panel <->
/// inserter seam: which keys commit, navigate, or pass through; that the replace is deferred off the
/// keystroke's tap callback; that the delete count comes from the field's real text; and that focus
/// changes, disabling, and secure fields tear the capture down.
@MainActor
final class EmojiPickerControllerTests: XCTestCase {
    /// Retained for the whole test so the controller's `[weak self]` deferred replace still has a
    /// target when the main queue is drained.
    private var harnesses: [Harness] = []

    override func tearDown() {
        harnesses.removeAll()
        super.tearDown()
    }

    private func makeHarness(precedingText: String = ":smile", isSecure: Bool = false) -> Harness {
        let harness = Harness(precedingText: precedingText, isSecure: isSecure)
        harnesses.append(harness)
        return harness
    }

    // MARK: - Commit

    func test_acceptKeyCommitIsDeferredThenInsertsSelectedGlyph() {
        let harness = makeHarness()
        harness.type(":smile")

        XCTAssertTrue(harness.controller.observe(InlineFeatureKeys.key(InlineFeatureKeys.tab)))
        XCTAssertEqual(harness.controller.decideCaptureKey(InlineFeatureKeys.tapEvent(InlineFeatureKeys.tab)), .consume)
        XCTAssertTrue(
            harness.inserter.calls.isEmpty,
            "The replace must be deferred off the keystroke's tap callback."
        )
        XCTAssertFalse(harness.panel.isVisible)
        XCTAssertFalse(harness.controller.isCapturing)

        drainInlineFeatureMainQueue()

        XCTAssertEqual(harness.inserter.calls, [.init(deleteCount: 6, text: "😄")])   // ":smile"
        XCTAssertEqual(harness.focus.refreshCount, 1, "The field must be re-read after the replace")
        XCTAssertEqual(
            harness.usage.recorded,
            ["smile"],
            "Commit must record the committed emoji's primary alias for ranking and recents."
        )
    }

    func test_deleteCountComesFromTheFieldsMeasuredRunNotTheTypedLength() {
        // Host autocorrect (or a dropped keystroke) left only ":smi" in the field even though the
        // observer saw ":smile". Deleting the typed length would eat two unrelated characters.
        let harness = makeHarness(precedingText: "hi :smi")
        harness.type(":smile")

        harness.controller.observe(InlineFeatureKeys.key(InlineFeatureKeys.tab))
        drainInlineFeatureMainQueue()

        XCTAssertEqual(harness.inserter.calls, [.init(deleteCount: 4, text: "😄")])
    }

    func test_deleteCountFallsBackToTypedLengthWhenFieldHasNoQueryRun() {
        let harness = makeHarness(precedingText: "done.")
        harness.type(":smile")

        harness.controller.observe(InlineFeatureKeys.key(InlineFeatureKeys.tab))
        drainInlineFeatureMainQueue()

        XCTAssertEqual(harness.inserter.calls, [.init(deleteCount: 6, text: "😄")], "\":\" + \"smile\"")
    }

    func test_rebindingAcceptKeyIsHonoredForCommit() {
        let harness = makeHarness()
        harness.monitor.wordAcceptKeyCode = 50   // user rebinds accept-word to backtick
        harness.type(":smile")

        XCTAssertTrue(harness.controller.observe(InlineFeatureKeys.key(50)))
        drainInlineFeatureMainQueue()

        XCTAssertEqual(harness.inserter.calls, [.init(deleteCount: 6, text: "😄")])
    }

    func test_closingColonReplacesWholeRunAndLetsTheColonThrough() {
        let harness = makeHarness(precedingText: ":smile:")
        harness.type(":smile")

        XCTAssertTrue(harness.controller.observe(InlineFeatureKeys.character(":")))
        XCTAssertEqual(
            harness.controller.decideCaptureKey(InlineFeatureKeys.tapEvent(InlineFeatureKeys.characterKeyCode)),
            .passThrough,
            "The closing colon must reach the field; the whole `:smile:` run is replaced afterwards."
        )
        XCTAssertTrue(harness.inserter.calls.isEmpty)

        drainInlineFeatureMainQueue()

        XCTAssertEqual(harness.inserter.calls, [.init(deleteCount: 7, text: "😄")])
        XCTAssertEqual(harness.usage.recorded, ["smile"])
    }

    func test_closingColonWithNoMatchLeavesLiteralTextUntouched() {
        let harness = makeHarness(precedingText: ":zzzzz:")
        harness.type(":zzzzz:")
        drainInlineFeatureMainQueue()

        XCTAssertTrue(harness.inserter.calls.isEmpty)
        XCTAssertTrue(harness.usage.recorded.isEmpty)
        XCTAssertFalse(harness.panel.isVisible)
    }

    func test_panelClickCommitsTheClickedRow() {
        let harness = makeHarness()
        harness.type(":smile")
        XCTAssertEqual(harness.panel.presentations.last?.glyphs, ["😄", "😃"])

        harness.panel.onSelectIndex?(1)
        drainInlineFeatureMainQueue()

        XCTAssertEqual(harness.inserter.calls, [.init(deleteCount: 6, text: "😃")])
        XCTAssertEqual(harness.usage.recorded, ["smiley"])
    }

    // MARK: - Pass-through keys

    func test_returnDismissesAndPassesThroughEvenWithMatches() {
        let harness = makeHarness()
        harness.type(":smile")

        XCTAssertTrue(harness.controller.observe(InlineFeatureKeys.key(InlineFeatureKeys.returnKey)))
        XCTAssertEqual(
            harness.controller.decideCaptureKey(InlineFeatureKeys.tapEvent(InlineFeatureKeys.returnKey)),
            .passThrough
        )
        drainInlineFeatureMainQueue()

        XCTAssertTrue(harness.inserter.calls.isEmpty, "Return must not insert the emoji.")
        XCTAssertFalse(harness.panel.isVisible)
    }

    func test_acceptKeyWithNoMatchesPassesThroughWithoutInserting() {
        let harness = makeHarness(precedingText: ":zzzzz")
        harness.type(":zzzzz")

        // Never steal the accept key when there is nothing to insert, so a real word-accept still
        // reaches the suggestion pipeline.
        XCTAssertTrue(harness.controller.observe(InlineFeatureKeys.key(InlineFeatureKeys.tab)))
        XCTAssertEqual(harness.controller.decideCaptureKey(InlineFeatureKeys.tapEvent(InlineFeatureKeys.tab)), .passThrough)
        drainInlineFeatureMainQueue()

        XCTAssertTrue(harness.inserter.calls.isEmpty)
    }

    func test_escapeIsConsumedAndCancelsWithoutInserting() {
        let harness = makeHarness()
        harness.type(":smile")

        XCTAssertTrue(harness.controller.observe(InlineFeatureKeys.key(InlineFeatureKeys.escape)))
        XCTAssertEqual(harness.controller.decideCaptureKey(InlineFeatureKeys.tapEvent(InlineFeatureKeys.escape)), .consume)
        drainInlineFeatureMainQueue()

        XCTAssertTrue(harness.inserter.calls.isEmpty)
        XCTAssertFalse(harness.panel.isVisible)
        XCTAssertFalse(harness.controller.isCapturing)
    }

    func test_commandModifiedKeyDismissesCapture() {
        let harness = makeHarness()
        harness.type(":smile")

        // Cmd+Tab-style shortcuts must never be read as the accept key.
        harness.controller.observe(InlineFeatureKeys.key(InlineFeatureKeys.tab, flags: .maskCommand))
        XCTAssertEqual(harness.controller.decideCaptureKey(InlineFeatureKeys.tapEvent(InlineFeatureKeys.tab)), .passThrough)
        drainInlineFeatureMainQueue()

        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertTrue(harness.inserter.calls.isEmpty)
    }

    func test_backspaceShortensQueryButOptionBackspaceDismisses() {
        let harness = makeHarness()
        harness.type(":smile")

        harness.controller.observe(InlineFeatureKeys.key(InlineFeatureKeys.backspace))
        XCTAssertTrue(harness.controller.isCapturing)
        XCTAssertEqual(harness.panel.presentations.last?.query, "smil")

        // Option+Backspace deletes a whole word, which the single-character query cannot track.
        harness.controller.observe(InlineFeatureKeys.key(InlineFeatureKeys.backspace, flags: .maskAlternate))
        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertFalse(harness.panel.isVisible)
    }

    // MARK: - Navigation

    func test_everyArrowIsConsumedAndKeepsPanelOpenWhenMatchesPresent() {
        let arrows: [(name: String, keyCode: CGKeyCode)] = [
            ("left", InlineFeatureKeys.left), ("right", InlineFeatureKeys.right),
            ("up", InlineFeatureKeys.up), ("down", InlineFeatureKeys.down)
        ]
        for arrow in arrows {
            let harness = makeHarness()
            harness.type(":smile")

            XCTAssertTrue(harness.controller.observe(InlineFeatureKeys.key(arrow.keyCode)), arrow.name)
            XCTAssertEqual(
                harness.controller.decideCaptureKey(InlineFeatureKeys.tapEvent(arrow.keyCode)),
                .consume,
                arrow.name
            )
            XCTAssertTrue(harness.panel.isVisible, arrow.name)
        }
    }

    func test_selectionWrapsInBothDirectionsAndCommitUsesIt() {
        let harness = makeHarness()
        harness.type(":smile")   // matches: [😄 exact alias, 😃 alias prefix]

        // Previous from the first row wraps to the last; next from the last wraps back to the first.
        harness.controller.observe(InlineFeatureKeys.key(InlineFeatureKeys.left))
        harness.controller.observe(InlineFeatureKeys.key(InlineFeatureKeys.right))
        harness.controller.observe(InlineFeatureKeys.key(InlineFeatureKeys.up))
        XCTAssertEqual(harness.panel.selectedIndexUpdates, [1, 0, 1])

        harness.controller.observe(InlineFeatureKeys.key(InlineFeatureKeys.tab))
        drainInlineFeatureMainQueue()

        XCTAssertEqual(harness.inserter.calls.map(\.text), ["😃"])
    }

    func test_arrowWithNoMatchesPassesThroughAndClosesCapture() {
        let harness = makeHarness(precedingText: ":zzzzz")
        harness.type(":zzzzz")

        // With nothing to move through, the arrow must reach the host so the caret still moves.
        XCTAssertTrue(harness.controller.observe(InlineFeatureKeys.key(InlineFeatureKeys.right)))
        XCTAssertEqual(harness.controller.decideCaptureKey(InlineFeatureKeys.tapEvent(InlineFeatureKeys.right)), .passThrough)
        XCTAssertFalse(harness.panel.isVisible)
    }

    // MARK: - Decider contract

    func test_deciderIgnoresKeysWithoutAMatchingObserverPass() {
        let harness = makeHarness()
        harness.type(":smile")
        harness.controller.observe(InlineFeatureKeys.key(InlineFeatureKeys.right))

        // A decision recorded for Right must not be applied to a different key, and is single-use.
        XCTAssertEqual(harness.controller.decideCaptureKey(InlineFeatureKeys.tapEvent(InlineFeatureKeys.tab)), .notHandled)
        XCTAssertEqual(harness.controller.decideCaptureKey(InlineFeatureKeys.tapEvent(InlineFeatureKeys.right)), .consume)
        XCTAssertEqual(harness.controller.decideCaptureKey(InlineFeatureKeys.tapEvent(InlineFeatureKeys.right)), .notHandled)
    }

    func test_ordinaryTypingIsNotInvolved() {
        let harness = makeHarness(precedingText: "hello")
        for character in "hello" {
            XCTAssertFalse(harness.controller.observe(InlineFeatureKeys.character(character)), "\(character)")
        }
        XCTAssertEqual(
            harness.controller.decideCaptureKey(InlineFeatureKeys.tapEvent(InlineFeatureKeys.characterKeyCode)),
            .notHandled
        )
        XCTAssertTrue(harness.panel.presentations.isEmpty)
    }

    // MARK: - Capture lifecycle and gating

    func test_bareColonOpensPanelImmediatelyAndNotifiesOnOpenAndTeardownOnly() {
        let harness = makeHarness()

        XCTAssertTrue(harness.controller.observe(InlineFeatureKeys.character(":")))
        XCTAssertTrue(harness.controller.isCapturing)
        XCTAssertEqual(harness.panel.presentations.last?.query, "")
        XCTAssertEqual(harness.captureStateChanges, 1)

        // The callback exists for teardown *outside* an `observe` pass (the coordinator already
        // recomputes interception after every observed key), so click-away is the path to pin.
        harness.panel.onClickOutside?()
        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertEqual(harness.captureStateChanges, 2)

        // Tearing down an already-idle controller must not emit a spurious change.
        harness.controller.stop()
        XCTAssertEqual(harness.captureStateChanges, 2)
    }

    func test_secureFieldAbortsOpenWithoutShowingPanel() {
        let harness = makeHarness(isSecure: true)

        XCTAssertFalse(harness.controller.observe(InlineFeatureKeys.character(":")))
        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertTrue(harness.panel.presentations.isEmpty)
        XCTAssertEqual(harness.captureStateChanges, 0)
    }

    func test_disablingMidCaptureCancelsAndStandsDown() {
        let harness = makeHarness()
        harness.type(":smi")

        harness.enabled = false

        XCTAssertFalse(harness.controller.observe(InlineFeatureKeys.key(InlineFeatureKeys.tab)))
        XCTAssertEqual(harness.controller.decideCaptureKey(InlineFeatureKeys.tapEvent(InlineFeatureKeys.tab)), .notHandled)
        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertFalse(harness.panel.isVisible)
    }

    func test_focusSnapshotForSameFieldRepositionsPanelAtNewCaret() {
        let harness = makeHarness()
        harness.type(":smi")
        let movedCaret = CGRect(x: 90, y: 40, width: 2, height: 18)

        harness.focus.publish(precedingText: ":smi", focusChangeSequence: 1, caretRect: movedCaret)

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
            harness.type(":smi")

            harness.focus.publish(isSecure: testCase.isSecure, focusChangeSequence: testCase.sequence)

            XCTAssertFalse(harness.controller.isCapturing, testCase.name)
            XCTAssertFalse(harness.panel.isVisible, testCase.name)
            XCTAssertEqual(harness.captureStateChanges, 2, "\(testCase.name): open + teardown")
        }
    }

    func test_clickOutsideCancelsCapture() {
        let harness = makeHarness()
        harness.type(":smi")

        harness.panel.onClickOutside?()

        XCTAssertFalse(harness.controller.isCapturing)
        XCTAssertFalse(harness.panel.isVisible)
    }

    // MARK: - Harness

    @MainActor
    private final class Harness {
        let focus: InlineFeatureFocusStub
        let monitor: InlineFeatureInputMonitorStub
        let inserter: InlineFeatureRecordingInserter
        let panel: InlineFeatureEmojiPanelStub
        let usage: UsageRecorder
        let controller: EmojiPickerController
        private let enabledBox: EnabledBox
        private(set) var captureStateChanges = 0

        /// Read live by the controller's `isEnabled` closure, so flipping it mid-capture is observed
        /// on the next keystroke.
        var enabled: Bool {
            get { enabledBox.value }
            set { enabledBox.value = newValue }
        }

        init(precedingText: String, isSecure: Bool) {
            // Two entries so navigation has somewhere to go: ":smile" ranks the exact alias first
            // and the "smiley" alias prefix second.
            let catalog = EmojiCatalog(entries: [
                EmojiEntry(glyph: "😄", name: "smiling face", aliases: ["smile"], keywords: []),
                EmojiEntry(glyph: "😃", name: "grinning face with big eyes", aliases: ["smiley"], keywords: [])
            ])
            // Built as locals first: the controller's closures capture these objects rather than
            // `self`, which is not usable until every stored property is initialized.
            let focus = InlineFeatureFocusStub(precedingText: precedingText, isSecure: isSecure)
            let monitor = InlineFeatureInputMonitorStub()
            let inserter = InlineFeatureRecordingInserter()
            let panel = InlineFeatureEmojiPanelStub()
            let usage = UsageRecorder()
            let enabledBox = EnabledBox()
            self.focus = focus
            self.monitor = monitor
            self.inserter = inserter
            self.panel = panel
            self.usage = usage
            self.enabledBox = enabledBox
            controller = EmojiPickerController(
                matcherProvider: { EmojiMatcher(catalog: catalog) },
                panel: panel,
                focusModel: focus,
                inputMonitor: monitor,
                inserter: inserter,
                isEnabled: { enabledBox.value },
                emojiPreferences: { EmojiVariantPreferences(skinTone: .neutral, gender: .neutral) },
                emojiUsage: { usage.snapshot },
                recordEmojiUsage: { usage.recorded.append($0) }
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

/// Mutable flag the `isEnabled` closure reads, so a test can disable the feature mid-capture. Left
/// nonisolated because the controller's `isEnabled` parameter is a plain (non-actor) closure type.
private final class EnabledBox {
    var value = true
}

/// Captures the controller's usage callbacks without the harness capturing `self` during init.
@MainActor
private final class UsageRecorder {
    var snapshot = EmojiUsageSnapshot.empty
    var recorded: [String] = []
}
