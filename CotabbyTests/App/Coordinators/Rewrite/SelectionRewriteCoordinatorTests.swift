import Combine
import XCTest
@testable import Cotabby

/// The coordinator's state machine: button after a stable selection, popup on press, one rewrite at a
/// time, Replace only over the original selection, and everything closed when the user moves on.
@MainActor
final class SelectionRewriteCoordinatorTests: XCTestCase {
    private static var retained: [AnyObject] = []

    @MainActor
    private final class Presenter: SelectionRewritePresenting {
        var isPopupKey = false
        var buttonPress: (() -> Void)?
        var popupModel: SelectionRewritePopupModel?
        var buttonFieldFrame: CGRect?
        func showButton(caretRect: CGRect, fieldFrame: CGRect?, onPress: @escaping () -> Void) {
            buttonPress = onPress; buttonFieldFrame = fieldFrame
        }
        var takesKeyboardCalls: [Bool] = []
        func showPopup(near anchor: CGRect, model: SelectionRewritePopupModel, takesKeyboard: Bool) {
            popupModel = model; buttonPress = nil; takesKeyboardCalls.append(takesKeyboard)
        }
        func refit() {}
        func hideAll() { buttonPress = nil; popupModel = nil; isPopupKey = false }
    }

    @MainActor
    private final class Output: SelectionRewriteTextOutput {
        var pasted: [String] = []
        var copied: [String] = []
        func paste(_ text: String) -> Bool { pasted.append(text); return true }
        func copyToClipboard(_ text: String) { copied.append(text) }
        func restoreSelection(_ range: NSRange, pid: pid_t) -> Bool { false }
        func activate(pid: pid_t) {}
    }

    @MainActor
    private final class Runner: SelectionRewriteRunning {
        var activeProviderSendsOffDevice = false
        var activeHostName: String?
        var result = "Please let me know if the dates work for you."
        var gate: CheckedContinuation<Void, Never>?
        var holds = false
        /// When true, the first call waits on `gate` and then throws `URLError(.cancelled)`, the way a
        /// superseded URLSession request fails. Later calls return at once.
        var cancelFirstAfterGate = false
        private(set) var calls = 0
        private(set) var requests: [RewriteRequest] = []
        func rewrite(_ request: RewriteRequest, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
            requests.append(request)
            calls += 1
            if calls == 1 && cancelFirstAfterGate {
                await withCheckedContinuation { gate = $0 }
                throw URLError(.cancelled)
            }
            if holds { await withCheckedContinuation { gate = $0 } }
            onPartial(result)
            return result
        }
    }

    private let draft = "Please let me know if te dates are ok and wors for you."
    private var subject = PassthroughSubject<FocusSnapshot, Never>()
    private var current = FocusSnapshot.inactive
    /// The Rewrite settings the coordinator reads; tests change it to flip the master switch.
    private var prefs = RewritePreferences.defaults
    private var enabledSubject = PassthroughSubject<Bool, Never>()

    private func snapshot(selected: String, element: String = "composer", preceding: String = "Dear Charlie, ") -> FocusSnapshot {
        let input = CotabbyTestFixtures.focusedInputSnapshot(
            bundleIdentifier: "net.whatsapp.WhatsApp", elementIdentifier: element, precedingText: preceding,
            selection: NSRange(location: 14, length: (selected as NSString).length),
            selectedText: selected, hostSelection: NSRange(location: 14, length: (selected as NSString).length)
        )
        return FocusSnapshot(applicationName: "WhatsApp", bundleIdentifier: "net.whatsapp.WhatsApp",
                             capability: selected.isEmpty ? .supported : .blocked("Text is currently selected."), context: input)
    }

    private func make(prefs: RewritePreferences = .defaults, languages: [String] = [])
        -> (SelectionRewriteCoordinator, Presenter, Output, Runner) {
        let presenter = Presenter(), output = Output(), runner = Runner()
        subject = PassthroughSubject()
        enabledSubject = PassthroughSubject()
        self.prefs = prefs
        let coordinator = SelectionRewriteCoordinator(
            snapshots: subject.eraseToAnyPublisher(),
            enabledChanges: enabledSubject.eraseToAnyPublisher(),
            currentSnapshot: { [unowned self] in self.current },
            refreshFocus: {},
            presenter: presenter, output: output, engine: runner,
            preferences: { [unowned self] in self.prefs }, isAppAllowed: { _ in true }, hotkey: nil, keyTap: nil,
            writingLanguages: { languages },
            stableSelectionDelay: 0
        )
        let objects: [AnyObject] = [coordinator, presenter, output, runner]
        Self.retained.append(contentsOf: objects)
        coordinator.start()
        return (coordinator, presenter, output, runner)
    }

    private func send(_ snapshot: FocusSnapshot) async {
        current = snapshot
        subject.send(snapshot)
        await Task.yield(); await Task.yield()
        try? await Task.sleep(nanoseconds: 5_000_000)
    }

    func test_stableSelectionShowsButtonAndPressOpensPopup() async {
        let (_, presenter, _, _) = make()
        await send(snapshot(selected: draft))
        XCTAssertNotNil(presenter.buttonPress)
        presenter.buttonPress?()
        XCTAssertNotNil(presenter.popupModel)
        XCTAssertEqual(presenter.popupModel?.phase, .actions)
    }

    /// The button takes the place of the field-edge Cotabby icon, so it needs the field's own frame;
    /// placed at the caret it would cover the start of the selection.
    func test_buttonIsPlacedFromTheFieldFrame() async {
        let (_, presenter, _, _) = make()
        await send(snapshot(selected: draft))
        XCTAssertEqual(presenter.buttonFieldFrame, CGRect(x: 0, y: 0, width: 240, height: 32))
    }

    /// The request names the selection's language among the user's, so the model keeps it.
    func test_requestNamesTheSelectionsLanguage() async {
        let (_, presenter, _, runner) = make(languages: ["English", "Turkish"])
        await send(snapshot(selected: "bu aksam party var, sen de gel lutfen"))
        presenter.buttonPress?()
        presenter.popupModel?.onAction(.fixOnly)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(runner.requests.first?.language, "Turkish")
    }

    func test_fixTickBoxReachesTheRequest() async {
        let (_, presenter, _, runner) = make()
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        presenter.popupModel?.fixesMistakes = false
        presenter.popupModel?.onAction(.formal)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(runner.requests.first?.fixesMistakes, false)
    }

    /// After a tone, Shorter refines the preview itself, keeping the tone; Replace still replaces
    /// the original selection.
    func test_shorterRefinesThePreviewAndKeepsTheTone() async {
        let (_, presenter, output, runner) = make()
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        presenter.popupModel?.onAction(.family)
        try? await Task.sleep(nanoseconds: 30_000_000)
        let first = runner.result
        runner.result = "Do the dates work for you?"
        presenter.popupModel?.onRefine(.shorter)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(runner.requests.count, 2)
        XCTAssertEqual(runner.requests.last?.selection, first)
        XCTAssertEqual(runner.requests.last?.action, .shorter)
        XCTAssertEqual(runner.requests.last?.tone, .family)
        XCTAssertEqual(presenter.popupModel?.phase, .preview(text: "Do the dates work for you?", unsupported: []))
        presenter.popupModel?.onReplace()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(output.pasted, ["Do the dates work for you?"])
    }

    /// The master switch off means no selection work: no wand, and the shortcut does nothing.
    func test_rewriteOffArmsNothing() async {
        var prefs = RewritePreferences.defaults
        prefs.isEnabled = false
        let (coordinator, presenter, _, _) = make(prefs: prefs)
        await send(snapshot(selected: draft))
        XCTAssertNil(presenter.buttonPress)
        coordinator.handleShortcut()
        XCTAssertNil(presenter.popupModel)
    }

    /// Turning rewrite off while a selection is armed (or the popup is open) closes it at once.
    func test_turningRewriteOffClosesAnArmedSelection() async {
        let (_, presenter, _, _) = make()
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        XCTAssertNotNil(presenter.popupModel)
        prefs.isEnabled = false
        enabledSubject.send(false)
        XCTAssertNil(presenter.popupModel)
        XCTAssertNil(presenter.buttonPress)
    }

    /// A change the user never accepted stays flagged through Shorter: the refinement is checked
    /// against the original selection, not against the earlier preview.
    func test_refinementKeepsAnUnacceptedChangeFlagged() async {
        let (_, presenter, output, runner) = make()
        runner.result = "I am 100% sure about the dates."
        await send(snapshot(selected: "i am 1000% sure about the dates"))
        presenter.buttonPress?()
        presenter.popupModel?.onAction(.formal)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(presenter.popupModel?.phase, .preview(text: runner.result, unsupported: ["100"]))
        runner.result = "I'm 100% sure."
        presenter.popupModel?.onRefine(.shorter)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(presenter.popupModel?.phase, .preview(text: "I'm 100% sure.", unsupported: ["100"]))
        presenter.popupModel?.onReplace()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(output.pasted.isEmpty, "plain Replace must stay off")
    }

    func test_buttonOffShowsNothingUntilShortcut() async {
        var prefs = RewritePreferences.defaults
        prefs.showsButtonOnSelection = false
        let (coordinator, presenter, _, _) = make(prefs: prefs)
        await send(snapshot(selected: draft))
        XCTAssertNil(presenter.buttonPress)
        coordinator.handleShortcut()
        XCTAssertNotNil(presenter.popupModel)
    }

    func test_actionPreviewsThenReplacePastes() async {
        let (_, presenter, output, runner) = make()
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        presenter.popupModel?.onAction(.fixOnly)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(presenter.popupModel?.phase, .preview(text: runner.result, unsupported: []))
        presenter.popupModel?.onReplace()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(output.pasted, [runner.result])
        XCTAssertNil(presenter.popupModel, "The popup closes after a successful replace")
    }

    func test_replaceAfterSelectionChangedCopiesInstead() async {
        let (_, presenter, output, runner) = make()
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        presenter.popupModel?.onAction(.rewrite)
        try? await Task.sleep(nanoseconds: 20_000_000)
        current = snapshot(selected: "something else entirely here")
        presenter.popupModel?.onReplace()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(output.pasted.isEmpty)
        XCTAssertEqual(output.copied, [runner.result])
        // The copy notice is shown without taking the keyboard from the host.
        XCTAssertEqual(presenter.takesKeyboardCalls.last, false)
    }

    func test_typingIntoHostWhileGeneratingClosesAndIgnoresResult() async {
        let (_, presenter, output, runner) = make()
        runner.holds = true
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        presenter.popupModel?.onAction(.rewrite)
        try? await Task.sleep(nanoseconds: 10_000_000)
        // Typing replaced the selection: the field now has a caret and different text.
        await send(snapshot(selected: ""))
        XCTAssertNil(presenter.popupModel)
        runner.gate?.resume()
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertTrue(output.pasted.isEmpty)
        XCTAssertTrue(output.copied.isEmpty)
    }

    func test_ungroundedNameBlocksReplace() async {
        let (_, presenter, output, runner) = make()
        runner.result = "Please let me know if the dates work for you and Sam."
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        presenter.popupModel?.onAction(.rewrite)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(presenter.popupModel?.phase, .preview(text: runner.result, unsupported: ["Sam"]))
        presenter.popupModel?.onReplace()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(output.pasted.isEmpty)
    }

    /// A changed name or number needs a deliberate click: plain Replace (and Return) stays off,
    /// "Replace anyway" pastes, and the warning says what changed.
    func test_replaceAnywayPastesDespiteTheWarning() async {
        let (_, presenter, output, runner) = make()
        runner.result = "Please let me know if the dates work for you and Sam."
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        presenter.popupModel?.onAction(.friendly)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(presenter.popupModel?.changeWarning, "The rewrite adds “Sam”, which isn't in your text.")
        presenter.popupModel?.onReplaceAnyway()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(output.pasted, [runner.result])
    }

    func test_pasteTheHostIgnoredIsCopied() async {
        let (_, presenter, output, runner) = make()
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        presenter.popupModel?.onAction(.fixOnly)
        try? await Task.sleep(nanoseconds: 20_000_000)
        presenter.popupModel?.onReplace()
        try? await Task.sleep(nanoseconds: 30_000_000)
        // The field still shows the old text: the paste never landed.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(output.copied, [runner.result])
    }

    func test_clearingSelectionHidesButton() async {
        let (_, presenter, _, _) = make()
        await send(snapshot(selected: draft))
        XCTAssertNotNil(presenter.buttonPress)
        await send(snapshot(selected: ""))
        XCTAssertNil(presenter.buttonPress)
    }

    func test_tooLongSelectionShowsTheMessage() async {
        let (_, presenter, _, _) = make()
        let long = String(repeating: "word ", count: 401) // 2,005 characters, over the 2,000 limit
        await send(snapshot(selected: long))
        XCTAssertNotNil(presenter.buttonPress)
        presenter.buttonPress?()
        XCTAssertEqual(presenter.popupModel?.phase, .failed("Selection too long to rewrite."))
    }

    func test_credentialFieldShowsNoButton() async {
        let (coordinator, presenter, _, _) = make()
        let input = CotabbyTestFixtures.focusedInputSnapshot(
            bundleIdentifier: "net.whatsapp.WhatsApp", elementIdentifier: "composer", precedingText: "",
            selection: NSRange(location: 0, length: (draft as NSString).length),
            selectedText: draft, hostSelection: NSRange(location: 0, length: (draft as NSString).length)
        )
        let credential = FocusSnapshot(applicationName: "WhatsApp", bundleIdentifier: "net.whatsapp.WhatsApp",
                                       capability: .blocked(CredentialFieldDetector.blockedReason), context: input)
        await send(credential)
        XCTAssertNil(presenter.buttonPress)
        // The shortcut must not open the popup for a credential field either.
        coordinator.handleShortcut()
        XCTAssertNil(presenter.popupModel)
    }

    func test_shortcutReopensAfterEsc() async {
        let (coordinator, presenter, _, _) = make()
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        XCTAssertNotNil(presenter.popupModel)
        presenter.popupModel?.onClose()
        XCTAssertNil(presenter.popupModel)
        // The selection is unchanged, so the shortcut must still be armed and reopen the popup.
        coordinator.handleShortcut()
        XCTAssertNotNil(presenter.popupModel)
    }

    func test_dismissedSelectionShowsNoButtonAgain() async {
        let (_, presenter, _, _) = make()
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        presenter.popupModel?.onClose()
        // Same selection reported again: the button must stay away.
        await send(snapshot(selected: draft))
        XCTAssertNil(presenter.buttonPress)
    }

    func test_retryWhileGeneratingIgnoresTheSupersededRun() async {
        let (_, presenter, _, runner) = make()
        runner.cancelFirstAfterGate = true
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        presenter.popupModel?.onAction(.rewrite)
        try? await Task.sleep(nanoseconds: 10_000_000)
        let firstGate = runner.gate
        // Retry supersedes the held first run; the second run completes straight away.
        runner.result = "Please let me know if the dates work for you soon."
        presenter.popupModel?.onRetry()
        try? await Task.sleep(nanoseconds: 20_000_000)
        // The superseded run now fails with URLError(.cancelled), as a cancelled URLSession request does.
        firstGate?.resume()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(presenter.popupModel?.phase, .preview(text: runner.result, unsupported: []))
    }

    /// A cloud provider is named in the popup before anything is sent; a local one adds no line.
    func test_disclosureNamesTheCloudHost() async {
        let (_, presenter, _, runner) = make()
        runner.activeProviderSendsOffDevice = true
        runner.activeHostName = "api.example.com"
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        XCTAssertEqual(presenter.popupModel?.disclosure, "The selected text is sent to api.example.com.")
    }

    func test_localProviderShowsNoDisclosure() async {
        let (_, presenter, _, _) = make()
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        XCTAssertNil(presenter.popupModel?.disclosure)
    }

    func test_verifySucceedsWithoutCopy() async {
        let (_, presenter, output, runner) = make()
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        presenter.popupModel?.onAction(.fixOnly)
        try? await Task.sleep(nanoseconds: 20_000_000)
        presenter.popupModel?.onReplace()
        try? await Task.sleep(nanoseconds: 30_000_000)
        // The host shows the rewrite in the same field now, so the poll sees it and nothing is copied.
        current = snapshot(selected: "", preceding: "Dear Charlie, " + runner.result)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(output.pasted, [runner.result])
        XCTAssertTrue(output.copied.isEmpty)
    }

    func test_verifyMatchesAcrossCollapsedParagraphs() async {
        let (_, presenter, output, runner) = make()
        runner.result = "Hi Charlie,\n\nthe 28th works."
        // The selection names Charlie and the 28th, so the rewrite is grounded and Replace stays on.
        await send(snapshot(selected: "Hi Charlie, the 28th works."))
        presenter.buttonPress?()
        presenter.popupModel?.onAction(.fixOnly)
        try? await Task.sleep(nanoseconds: 20_000_000)
        presenter.popupModel?.onReplace()
        try? await Task.sleep(nanoseconds: 30_000_000)
        // The host shows the paragraphs run together, with no line break, right before the caret.
        current = snapshot(selected: "", preceding: "Dear x Hi Charlie, the 28th works.")
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(output.pasted, [runner.result])
        XCTAssertTrue(output.copied.isEmpty)
    }

    func test_doubleReplacePastesOnce() async {
        let (_, presenter, output, runner) = make()
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        presenter.popupModel?.onAction(.fixOnly)
        try? await Task.sleep(nanoseconds: 20_000_000)
        // The popup holds the keyboard, so the activation wait runs and the first Replace is still in
        // flight when the second arrives. Waiting past the 100 ms settle shows any second paste.
        presenter.isPopupKey = true
        presenter.popupModel?.onReplace()
        presenter.popupModel?.onReplace()
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(output.pasted, [runner.result])
    }

    func test_closeDuringActivationWaitDoesNotPaste() async {
        let (_, presenter, output, runner) = make()
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        presenter.popupModel?.onAction(.fixOnly)
        try? await Task.sleep(nanoseconds: 20_000_000)
        presenter.isPopupKey = true
        presenter.popupModel?.onReplace()
        // Esc or ✕ lands during the 100 ms activation wait.
        presenter.popupModel?.onClose()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(output.pasted.isEmpty)
        XCTAssertTrue(output.copied.isEmpty)
    }
}
