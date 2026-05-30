import Combine
import CoreGraphics
import XCTest
// `@preconcurrency`: the fakes conform to `@MainActor` protocols whose closure properties (e.g.
// `emojiCaptureKeyDecider`) are not `@Sendable`, which trips a cross-module Swift 6 sendability
// warning on the conformance. The suppression is test-only and does not affect production code.
@preconcurrency @testable import Cotabby

/// Composition tests for the inline `:emoji:` commit path. The pure machine/matcher/run are covered
/// elsewhere; these lock down the controller <-> focus <-> inserter seam where the commit flakiness
/// lived: the replace must be deferred off the keystroke's tap callback, and it must not fire into a
/// field the user has navigated away from during that deferral.
final class EmojiPickerControllerTests: XCTestCase {
    @MainActor private static var retained: [EmojiPickerController] = []

    override func tearDown() {
        runOnMainActor { Self.retained.removeAll() }
        super.tearDown()
    }

    func test_acceptKeyCommitInsertsSelectedGlyphAfterRunloopTick() {
        runOnMainActor {
            let harness = Harness(precedingText: ":smile")   // accept-word key defaults to Tab (48)
            harness.openAndType(":smile")

            // The accept-word key commits, but the replace must be deferred, not posted synchronously
            // from inside the keystroke's tap callback.
            XCTAssertTrue(harness.controller.observe(Harness.keyEvent(48)))
            XCTAssertTrue(
                harness.inserter.calls.isEmpty,
                "The replace must be deferred off the keystroke's tap callback."
            )

            harness.flushMainQueue()

            XCTAssertEqual(harness.inserter.calls.map(\.text), ["😄"])
            XCTAssertEqual(harness.inserter.calls.first?.deleteCount, 6)   // ":smile"
            XCTAssertTrue(harness.panel.isHidden)
        }
    }

    func test_returnDoesNotCommitAndPassesThroughEvenWithMatches() {
        runOnMainActor {
            let harness = Harness(precedingText: ":smile")
            harness.openAndType(":smile")   // matches present

            // Return is no longer a commit key: it dismisses the picker and reaches the host.
            XCTAssertTrue(harness.controller.observe(Harness.keyEvent(36)))
            harness.flushMainQueue()

            XCTAssertTrue(harness.inserter.calls.isEmpty, "Return must not insert the emoji.")
            XCTAssertEqual(harness.controller.decideCaptureKey(Harness.monitorKey(36)), .passThrough)
            XCTAssertTrue(harness.panel.isHidden)
        }
    }

    func test_rebindingAcceptKeyIsHonoredForCommit() {
        runOnMainActor {
            let harness = Harness(precedingText: ":smile")
            harness.monitor.wordAcceptKeyCode = 50          // user rebinds accept-word to backtick (50)
            harness.openAndType(":smile")

            XCTAssertTrue(harness.controller.observe(Harness.keyEvent(50)))
            harness.flushMainQueue()

            XCTAssertEqual(harness.inserter.calls.map(\.text), ["😄"])
            XCTAssertEqual(harness.inserter.calls.first?.deleteCount, 6)
        }
    }

    func test_acceptKeyWithNoMatchesPassesThroughWithoutInserting() {
        runOnMainActor {
            let harness = Harness(precedingText: ":zzzzz")
            harness.openAndType(":zzzzz")   // no catalog match

            // The accept key with no match must not be stolen from the host, so a real word-accept
            // still reaches the suggestion pipeline.
            XCTAssertTrue(harness.controller.observe(Harness.keyEvent(48)))
            harness.flushMainQueue()

            XCTAssertTrue(harness.inserter.calls.isEmpty, "Nothing to commit, so nothing is inserted.")
            XCTAssertEqual(harness.controller.decideCaptureKey(Harness.monitorKey(48)), .passThrough)
        }
    }

    // MARK: - Harness

    @MainActor
    private final class Harness {
        let focus: FakeFocus
        let monitor = FakeInputMonitor()
        let inserter = RecordingInserter()
        let panel = FakePanel()
        let controller: EmojiPickerController

        init(precedingText: String) {
            let catalog = EmojiCatalog(entries: [
                EmojiEntry(
                    glyph: "😄",
                    name: "smiling face",
                    aliases: ["smile"],
                    keywords: [],
                    group: "Smileys & Emotion",
                    unicodeVersion: "6.0"
                )
            ])
            focus = FakeFocus(precedingText: precedingText, focusChangeSequence: 1)
            controller = EmojiPickerController(
                matcher: EmojiMatcher(catalog: catalog),
                panel: panel,
                focusModel: focus,
                inputMonitor: monitor,
                inserter: inserter,
                isEnabled: { true }
            )
            controller.start()
            EmojiPickerControllerTests.retained.append(controller)
        }

        func openAndType(_ text: String) {
            for character in text {
                _ = controller.observe(Harness.charEvent(character))
            }
        }

        /// Enqueues a fence after the controller's deferred replace (GCD main queue is FIFO) and
        /// spins the runloop until it drains, so the deferred work has run before assertions.
        func flushMainQueue() {
            let fence = XCTestExpectation(description: "flush main queue")
            DispatchQueue.main.async { fence.fulfill() }
            _ = XCTWaiter().wait(for: [fence], timeout: 1.0)
        }

        static func charEvent(_ character: Character) -> CapturedInputEvent {
            // Any non-special keyCode; the trigger/query is driven by the character, not the code.
            CapturedInputEvent(kind: .textMutation, keyCode: 41, characters: String(character), flags: [])
        }

        static func keyEvent(_ keyCode: CGKeyCode) -> CapturedInputEvent {
            CapturedInputEvent(kind: .textMutation, keyCode: keyCode, characters: "", flags: [])
        }

        static func monitorKey(_ keyCode: CGKeyCode) -> InputMonitorKeyEvent {
            InputMonitorKeyEvent(keyCode: keyCode)
        }
    }
}

// MARK: - Fakes

@MainActor
private final class FakeFocus: SuggestionFocusProviding {
    private(set) var snapshot: FocusSnapshot
    private let subject = PassthroughSubject<FocusSnapshot, Never>()
    var snapshotPublisher: AnyPublisher<FocusSnapshot, Never> { subject.eraseToAnyPublisher() }

    init(precedingText: String, focusChangeSequence: UInt64) {
        snapshot = FakeFocus.make(precedingText: precedingText, focusChangeSequence: focusChangeSequence)
    }

    func refreshNow() {}

    private static func make(precedingText: String, focusChangeSequence: UInt64) -> FocusSnapshot {
        let context = CotabbyTestFixtures.focusedInputSnapshot(
            precedingText: precedingText,
            focusChangeSequence: focusChangeSequence
        )
        return FocusSnapshot(
            applicationName: "TestApp",
            bundleIdentifier: "com.test.app",
            capability: .supported,
            context: context,
            inspection: nil
        )
    }
}

@MainActor
private final class FakeInputMonitor: EmojiInputIntercepting {
    var emojiCaptureKeyDecider: (@MainActor (InputMonitorKeyEvent) -> InputMonitorAcceptTapDecision)?
    var wordAcceptKeyCode: CGKeyCode = 48   // default Tab, matching the shipped accept-word default
    private(set) var captureActiveCalls: [Bool] = []

    func setCaptureInterceptionActive(_ active: Bool) { captureActiveCalls.append(active) }

    func isWordAcceptKey(_ keyEvent: InputMonitorKeyEvent) -> Bool {
        keyEvent.keyCode == wordAcceptKeyCode
    }
}

@MainActor
private final class RecordingInserter: EmojiTextInserting {
    struct Call: Equatable {
        let deleteCount: Int
        let text: String
    }

    private(set) var calls: [Call] = []

    func replace(deletingUTF16Count: Int, with text: String) -> Bool {
        calls.append(Call(deleteCount: deletingUTF16Count, text: text))
        return true
    }
}

@MainActor
private final class FakePanel: EmojiPickerPanelPresenting {
    var onSelectIndex: ((Int) -> Void)?
    var onClickOutside: (() -> Void)?
    private(set) var isHidden = false

    func show(query: String, matches: [EmojiMatch], selectedIndex: Int, caretRect: CGRect) {
        isHidden = false
    }

    func setSelectedIndex(_ index: Int) {}

    func hide() {
        isHidden = true
    }
}

private func runOnMainActor<Result>(
    _ body: @MainActor () throws -> Result
) rethrows -> Result {
    if Thread.isMainThread {
        return try MainActor.assumeIsolated(body)
    }

    return try DispatchQueue.main.sync {
        try MainActor.assumeIsolated(body)
    }
}
