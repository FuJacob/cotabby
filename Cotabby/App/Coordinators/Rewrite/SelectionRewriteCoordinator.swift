import AppKit
import Combine
import Foundation
import Logging

/// File overview:
/// Selection rewrite's state machine: hidden → button → popup → generating → preview.
///
/// 1. A selection in an eligible field (`SelectionRewriteEligibility`) that stays the same for
///    `stableSelectionDelay` turns the field-edge Cotabby icon into the rewrite button, if the setting
///    allows it, and arms the ⌃⌥R shortcut either way.
/// 2. The button or the shortcut opens the popup (`SelectionRewritePopupModel`), which names the
///    host the text goes to when the provider is a cloud service.
/// 3. An action runs one rewrite (`RewriteEngine`), streaming into the preview. A rewrite whose names
///    or numbers are not in the selection (`RewriteSpecificsCheck`) previews with plain Replace off.
/// 4. Replace re-validates the selection (`SelectionReplaceValidator`), restoring it once if focus
///    came back from the instruction box, then pastes over it; any mismatch copies the result to the
///    clipboard instead.
///
/// Anything that means the user moved on closes everything and cancels the rewrite: another
/// selection, typing (the selection is replaced or gone), another field or app, Esc. Nothing is
/// stored. Built by `CotabbyAppEnvironment`, started and stopped by `AppDelegate`.
@MainActor
final class SelectionRewriteCoordinator {
    private let snapshots: AnyPublisher<FocusSnapshot, Never>
    /// The Rewrite master switch as it changes, so turning it off tears down an armed selection at
    /// once instead of at the next focus change.
    private let enabledChanges: AnyPublisher<Bool, Never>
    private let currentSnapshot: @MainActor () -> FocusSnapshot
    private let refreshFocus: @MainActor () -> Void
    private let presenter: SelectionRewritePresenting
    private let output: SelectionRewriteTextOutput
    private let engine: SelectionRewriteRunning
    private let preferences: @MainActor () -> RewritePreferences
    /// Whether Cotabby is on where the selection is (app, domain, pause, Low Power Mode). Asked when
    /// a selection arms and again before the popup opens or a rewrite runs, because those switches
    /// can change while a selection stays armed.
    private let isAppAllowed: @MainActor (FocusedInputSnapshot) -> Bool
    /// The ⌃⌥R shortcut, armed only while an eligible selection exists.
    private let hotkey: TemporaryKeyTap?
    /// Esc and Return while the popup is open.
    private let keyTap: TemporaryKeyTap?
    private let stableSelectionDelay: UInt64
    /// The languages the user declared in Settings → Writing, which limit language detection.
    private let writingLanguages: @MainActor () -> [String]

    private var cancellables: Set<AnyCancellable> = []
    private var target: SelectionRewriteTarget?
    private var targetInput: FocusedInputSnapshot?
    private var stableTask: Task<Void, Never>?
    private var rewriteTask: Task<Void, Never>?
    private var model: SelectionRewritePopupModel?
    /// What the last run did, for Retry: the action, the text it reshaped (nil: the user's selection),
    /// and the tone a refinement keeps.
    private var lastRun: RewriteRun?
    /// Identifies the newest rewrite run. A superseded run (Retry, or another action) can still throw
    /// or resolve after its replacement started, so every write after an `await` compares its own
    /// id with this before touching the popup. `close()` bumps it too, so closing cancels in-flight runs.
    private var runID = 0
    /// True from the moment Replace starts until its paste or copy notice is done. Focus snapshots
    /// arriving in that window reflect our own panel and paste, not the user moving on.
    private var isReplacing = false
    /// Remembers the popup's tick box in Settings while the popup is open.
    private var fixesMistakesCancellable: AnyCancellable?
    private let setFixesMistakes: @MainActor (Bool) -> Void
    /// The selection the user dismissed (✕, Esc, Copy, or a notice timing out). Its button stays hidden
    /// while the selection is unchanged, but ⌃⌥R still reopens the popup for it. Cleared by `close()`.
    private var dismissedTarget: SelectionRewriteTarget?

    static let escapeKeyCode: CGKeyCode = 53
    static let returnKeyCode: CGKeyCode = 36

    init(
        snapshots: AnyPublisher<FocusSnapshot, Never>,
        enabledChanges: AnyPublisher<Bool, Never> = Empty().eraseToAnyPublisher(),
        currentSnapshot: @escaping @MainActor () -> FocusSnapshot,
        refreshFocus: @escaping @MainActor () -> Void,
        presenter: SelectionRewritePresenting,
        output: SelectionRewriteTextOutput,
        engine: SelectionRewriteRunning,
        preferences: @escaping @MainActor () -> RewritePreferences,
        isAppAllowed: @escaping @MainActor (FocusedInputSnapshot) -> Bool,
        hotkey: TemporaryKeyTap?,
        keyTap: TemporaryKeyTap?,
        writingLanguages: @escaping @MainActor () -> [String] = { [] },
        setFixesMistakes: @escaping @MainActor (Bool) -> Void = { _ in },
        stableSelectionDelay: UInt64 = 250_000_000
    ) {
        self.snapshots = snapshots
        self.enabledChanges = enabledChanges
        self.currentSnapshot = currentSnapshot
        self.refreshFocus = refreshFocus
        self.presenter = presenter
        self.output = output
        self.engine = engine
        self.preferences = preferences
        self.isAppAllowed = isAppAllowed
        self.hotkey = hotkey
        self.keyTap = keyTap
        self.writingLanguages = writingLanguages
        self.setFixesMistakes = setFixesMistakes
        self.stableSelectionDelay = stableSelectionDelay
    }

    nonisolated deinit {}

    func start() {
        snapshots.sink { [weak self] in self?.observe($0) }.store(in: &cancellables)
        // Switching rewrite on needs no work here: the next focus snapshot arms a selection.
        enabledChanges.sink { [weak self] enabled in
            if !enabled { self?.close() }
        }
        .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        close()
    }

    // MARK: - Observing the selection

    private func observe(_ snapshot: FocusSnapshot) {
        if isReplacing { return }
        // Off means no selection work at all: no eligibility check, no wand, no key tap.
        guard preferences().isEnabled else {
            close()
            return
        }
        // While the user types in the popup's instruction box, focus reports Cotabby or no field;
        // that is not the user leaving the selection.
        if presenter.isPopupKey, snapshot.context == nil || snapshot.bundleIdentifier == Bundle.main.bundleIdentifier {
            return
        }
        guard let input = rewritableInput(in: snapshot) else {
            close()
            return
        }
        let candidate = SelectionRewriteTarget(snapshot: input)
        if candidate == target { return }
        close()
        target = candidate
        targetInput = input
        stableTask = Task { [weak self] in
            guard let self else { return }
            if self.stableSelectionDelay > 0 {
                try? await Task.sleep(nanoseconds: self.stableSelectionDelay)
            }
            guard !Task.isCancelled, self.target == candidate else { return }
            self.armSelection(input)
        }
    }

    private func armSelection(_ input: FocusedInputSnapshot) {
        let prefs = preferences()
        // Only an exact match is consumed, so the shortcut never reaches the host app while every
        // other key passes through untouched.
        hotkey?.install { [weak self] keyCode, flags in
            guard keyCode == prefs.shortcutKeyCode,
                  ShortcutModifierMask(eventFlags: flags).rawValue == prefs.shortcutModifiers
            else { return .pass }
            DispatchQueue.main.async { self?.handleShortcut() }
            return .consume
        }
        // A selection the user already dismissed keeps its shortcut but not its button.
        let isDismissed = dismissedTarget != nil && dismissedTarget == target
        if prefs.showsButtonOnSelection, !isDismissed {
            // The button replaces the field-edge Cotabby icon, so it is placed from the field's own frame.
            presenter.showButton(caretRect: input.caretRect, fieldFrame: input.elementFrameRect ?? input.inputFrameRect) { [weak self] in
                self?.openPopup()
            }
        }
    }

    /// ⌃⌥R: open the popup for the current selection.
    func handleShortcut() {
        guard preferences().isEnabled else { return }
        if target == nil, let input = rewritableInput(in: currentSnapshot()) {
            target = SelectionRewriteTarget(snapshot: input)
            targetInput = input
        }
        openPopup()
    }

    /// The field's input when the selection may arm the button and shortcut: an eligible selection, or
    /// one that is only too long (the popup then says so). Credential fields are never armed, even
    /// when the focus resolver kept their context.
    private func rewritableInput(in snapshot: FocusSnapshot) -> FocusedInputSnapshot? {
        guard snapshot.capability != .blocked(CredentialFieldDetector.blockedReason),
              let input = snapshot.context
        else { return nil }
        switch SelectionRewriteEligibility.verdict(for: input, appAllowed: isAppAllowed(input)) {
        case .eligible, .tooLong: return input
        case .noSelection, .tooShort, .ineligible: return nil
        }
    }

    // MARK: - The popup

    private func openPopup() {
        guard let input = targetInput, model == nil else { return }
        // Pause, Low Power Mode or a disabled app or domain may have come on since the selection armed.
        guard isAppAllowed(input) else { return close() }
        stableTask?.cancel()
        let prefs = preferences()
        let model = SelectionRewritePopupModel()
        model.fixesMistakes = prefs.fixesMistakes
        // `dropFirst` skips the value just seeded from Settings; only the user's own clicks are saved.
        fixesMistakesCancellable = model.$fixesMistakes.dropFirst().sink { [weak self] value in
            self?.setFixesMistakes(value)
        }
        model.disclosure = disclosure()
        model.onAction = { [weak self] in self?.run($0) }
        model.onRetry = { [weak self] in
            guard let self, let last = self.lastRun else { return }
            self.run(last.action, draft: last.draft, tone: last.tone)
        }
        model.onRefine = { [weak self] length in self?.refine(length) }
        model.onReplace = { [weak self] in self?.replace() }
        model.onReplaceAnyway = { [weak self] in self?.replace(acceptingChanges: true) }
        model.onCopy = { [weak self] in self?.copyPreview() }
        model.onClose = { [weak self] in self?.dismiss() }
        if input.selectedText.count > SelectionRewriteEligibility.maximumCharacters {
            model.phase = .failed(RewriteError.selectionTooLong.errorDescription ?? "Selection too long to rewrite.")
        }
        self.model = model
        presenter.showPopup(near: input.caretRect, model: model, takesKeyboard: true)
        keyTap?.install { [weak self] keyCode, _ in
            // The tap's decision runs on the main actor, so the popup state can be read here. Work the
            // decision triggers goes to the next main-queue turn, as the tap's rules require.
            if keyCode == Self.escapeKeyCode {
                DispatchQueue.main.async { self?.dismiss() }
                return .consume
            }
            guard keyCode == Self.returnKeyCode, let self, let model = self.model else { return .pass }
            switch Self.returnKeyAction(popupIsKey: self.presenter.isPopupKey, phase: model.phase) {
            case .passToPopup:
                return .pass
            case .replace:
                DispatchQueue.main.async { self.replace() }
                return .consume
            case .swallow:
                return .consume
            }
        }
    }

    /// Names the host the selected text goes to; nil when the provider stays on this Mac.
    private func disclosure() -> String? {
        guard engine.activeProviderSendsOffDevice, let host = engine.activeHostName else { return nil }
        return "The selected text is sent to \(host)."
    }

    /// Shorter or Longer on the preview: reshapes the text on screen and keeps the tone (or custom
    /// instruction) that produced it. Replace still targets the user's original selection.
    private func refine(_ length: RewriteAction) {
        guard let model, case .preview(let text, _) = model.phase, let last = lastRun else { return }
        run(length, draft: text, tone: last.tone ?? last.action)
    }

    /// Runs one rewrite. `draft` is the text to reshape (the user's selection when nil); `tone` is the
    /// tone a refinement keeps.
    private func run(_ action: RewriteAction, draft: String? = nil, tone: RewriteAction? = nil) {
        guard let input = targetInput, let model else { return }
        guard isAppAllowed(input) else { return close() }
        lastRun = RewriteRun(action: action, draft: draft, tone: tone)
        let source = draft ?? input.selectedText
        rewriteTask?.cancel()
        // A new run id supersedes any run still in flight for this popup (Retry reuses the same model,
        // so the model check alone cannot tell the two apart).
        runID += 1
        let id = runID
        model.phase = .generating("")
        presenter.refit()
        // True only while this run is still the newest for this popup and has not been cancelled.
        let isCurrent = { [weak self, weak model] () -> Bool in
            guard let self, let model else { return false }
            return self.runID == id && self.model === model && !Task.isCancelled
        }
        rewriteTask = Task { [weak self] in
            guard let self else { return }
            do {
                var request = RewriteRequest(selection: source, action: action)
                request.tone = tone
                // Named in the prompt: Apple's model otherwise answered a Turkish draft in English.
                request.language = RewriteLanguageDetector.language(of: input.selectedText, among: self.writingLanguages())
                request.fixesMistakes = model.fixesMistakes
                let text = try await self.engine.rewrite(
                    request,
                    onPartial: { partial in
                        guard isCurrent(), case .generating = model.phase else { return }
                        model.phase = .generating(partial)
                    }
                )
                guard isCurrent() else { return }
                // Always checked against the user's own selection, never an earlier preview: a refinement
                // that keeps a change the user never accepted ("1000" → "100") must still be flagged.
                let ownText = input.selectedText
                let unsupported = RewriteSpecificsCheck.unsupportedSpecifics(in: text, source: ownText)
                model.changeWarning = RewriteChangeWarning.message(selection: ownText, rewrite: text, unsupported: unsupported)
                model.phase = .preview(text: text, unsupported: unsupported)
            } catch is CancellationError {
                return
            } catch {
                // A superseded run can fail with URLError(.cancelled) rather than CancellationError;
                // the token check keeps that failure off the newer run's popup.
                guard isCurrent() else { return }
                model.phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            self.presenter.refit()
        }
    }

    // MARK: - Replace and copy

    /// Starts Replace. Guarded synchronously so a stale preview never starts the flow; `isReplacing`
    /// is set here, before the task runs, so no focus snapshot slips in between. A preview whose
    /// rewrite changed a name or number the user wrote replaces only with `acceptingChanges`: the
    /// popup's "Replace anyway", never plain Replace or Return.
    private func replace(acceptingChanges: Bool = false) {
        // `!isReplacing` makes a double Return or double click a no-op while the first Replace is in flight.
        guard !isReplacing, let model, target != nil, case .preview(_, let unsupported) = model.phase,
              unsupported.isEmpty || acceptingChanges else { return }
        isReplacing = true
        Task { @MainActor in await self.performReplace() }
    }

    private func performReplace() async {
        defer { isReplacing = false }
        guard let model, let target, case .preview(let text, _) = model.phase else { return }
        let wasTyping = presenter.isPopupKey
        presenter.hideAll()
        if wasTyping {
            output.activate(pid: target.processIdentifier)
            // Activation is not instant: give the host time to take key status back before the focus
            // read and validation below, otherwise they see the popup's own field.
            try? await Task.sleep(nanoseconds: 100_000_000)
            // Esc or ✕ during the wait closes the popup: the user backed out, so nothing is pasted.
            guard self.model === model else { return }
        }
        refreshFocus()
        var outcome = SelectionReplaceValidator.outcome(target: target, current: currentSnapshot().context)
        if outcome == .restoreSelectionThenReplace, let range = target.hostSelection,
           output.restoreSelection(range, pid: target.processIdentifier) {
            refreshFocus()
            outcome = SelectionReplaceValidator.outcome(target: target, current: currentSnapshot().context)
        }
        switch outcome {
        case .replace where output.paste(text):
            CotabbyLogger.app.info("Rewrite replaced", metadata: ["category": "rewrite", "characters": .stringConvertible(text.count)])
            // `close()` clears the input the notice would anchor to, so its caret rect is read first.
            let anchor = targetInput?.caretRect ?? .zero
            close()
            verifyInserted(text, original: target.selectedText, in: target, anchor: anchor)
        case .copyInstead(let reason):
            copyAndNotify(text, reason: reason)
        default:
            copyAndNotify(text, reason: "Couldn't replace the selection — copied to clipboard.")
        }
    }

    /// Spec: "after inserting, poll until Accessibility shows the new text". Some hosts swallow a
    /// paste silently; then the result goes to the clipboard so it is not lost. Polls up to 5 times
    /// over about a second, after the inserter has restored the user's clipboard (~0.3 s). Only a miss
    /// in the same field after every poll copies and shows the notice.
    private func verifyInserted(_ text: String, original: String, in target: SelectionRewriteTarget, anchor: CGRect) {
        guard !Self.squeezed(text).isEmpty else { return }
        Task { [weak self] in
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                self.refreshFocus()
                // The user moved on (another field, or no field): stop without copying. The paste most
                // likely landed in the field they left, and copying now would overwrite their clipboard.
                guard let input = self.currentSnapshot().context,
                      SelectionRewriteTarget.fieldKey(for: input) == target.fieldKey
                else { return }
                if Self.pasteLanded(text, replacing: original, in: input) { return }
            }
            guard let self else { return }
            self.output.copyToClipboard(text)
            CotabbyLogger.app.warning("Rewrite not seen in the field; copied to clipboard", metadata: ["category": "rewrite"])
            self.showNotice("Couldn't confirm the replace — copied to clipboard.", anchor: anchor)
        }
    }

    /// Whether the field shows the rewrite where the selection was. Hosts report the same text
    /// differently (some run paragraphs together, some wrap lines), so whitespace is ignored on both
    /// sides. A paste that landed leaves the caret right after the rewrite, so the text before the
    /// caret ends with it; failing that, the whole rewrite must be in the field and the original
    /// selection gone. A shared opening alone ("Please send the report today." pasted over "Please
    /// send the report tomorrow.") is never enough.
    static func pasteLanded(_ rewrite: String, replacing original: String, in input: FocusedInputSnapshot) -> Bool {
        let expected = squeezed(rewrite)
        guard !expected.isEmpty else { return true }
        // The last part of a long rewrite is enough here, and fits in the bounded text before the caret.
        if squeezed(input.precedingText).hasSuffix(expected.suffix(1_000)) { return true }
        let field = squeezed(input.precedingText + input.selectedText + input.trailingText)
        let originalText = squeezed(original)
        let originalGone = originalText.isEmpty || expected.contains(originalText) || !field.contains(originalText)
        return field.contains(expected) && originalGone
    }

    /// The text with every whitespace character removed.
    private static func squeezed(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    /// A short notice in a fresh popup that does not take the keyboard, closed after 2.5 s. Used after
    /// a successful paste, when no popup is left to reuse. Skipped when another popup is already open.
    private func showNotice(_ reason: String, anchor: CGRect) {
        guard model == nil else { return }
        let notice = SelectionRewritePopupModel()
        notice.phase = .notice(reason)
        model = notice
        presenter.showPopup(near: anchor, model: notice, takesKeyboard: false)
        Task { [weak self, weak notice] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, let notice, self.model === notice else { return }
            self.dismiss()
        }
    }

    /// What Return does while the popup is open.
    enum ReturnKeyAction: Equatable {
        /// The popup has the keyboard: its own default button or text field handles Return.
        case passToPopup
        /// The host has the keyboard and the preview may replace: Return replaces.
        case replace
        /// The host has the keyboard but nothing may replace yet (still generating, a change warning,
        /// an error): Return is taken anyway, because in a chat app it would send the original draft.
        case swallow
    }

    /// The Return decision, pure so the "never reaches the host while the popup is open" rule is
    /// pinned by tests. A notice has no key tap at all, so it never gets here.
    static func returnKeyAction(popupIsKey: Bool, phase: SelectionRewritePopupModel.Phase) -> ReturnKeyAction {
        if popupIsKey { return .passToPopup }
        if case .preview(_, let unsupported) = phase, unsupported.isEmpty { return .replace }
        return .swallow
    }

    private func copyPreview() {
        guard let model, case .preview(let text, _) = model.phase else { return }
        output.copyToClipboard(text)
        dismiss()
    }

    private func copyAndNotify(_ text: String, reason: String) {
        output.copyToClipboard(text)
        CotabbyLogger.app.info("Rewrite copied instead", metadata: ["category": "rewrite", "reason": .string(reason)])
        guard let model, let input = targetInput else { return close() }
        model.phase = .notice(reason)
        // A notice takes no keys: Esc and Return belong to the host again while it is on screen.
        keyTap?.remove()
        presenter.showPopup(near: input.caretRect, model: model, takesKeyboard: false)
        Task { [weak self, weak model] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, let model, self.model === model else { return }
            self.dismiss()
        }
    }

    /// The user dismissed the popup (✕, Esc, Copy, or a notice timing out). Closes the popup and any
    /// rewrite in flight, but keeps the selection target and the ⌃⌥R hotkey: `observe` does not re-arm an
    /// unchanged selection, so dropping the target would leave the shortcut dead until the selection
    /// changed. The button stays hidden for this selection (`dismissedTarget`).
    private func dismiss() {
        stableTask?.cancel()
        rewriteTask?.cancel()
        stableTask = nil
        rewriteTask = nil
        runID += 1
        fixesMistakesCancellable = nil
        model = nil
        lastRun = nil
        keyTap?.remove()
        presenter.hideAll()
        dismissedTarget = target
    }

    /// Full teardown: the selection is gone or the user moved on (another selection, another field or
    /// app, a successful Replace). Also removes the shortcut and forgets the dismissed selection.
    private func close() {
        stableTask?.cancel()
        rewriteTask?.cancel()
        stableTask = nil
        rewriteTask = nil
        // Invalidates any run still awaiting the engine: its writes check the token before touching the popup.
        runID += 1
        fixesMistakesCancellable = nil
        model = nil
        target = nil
        targetInput = nil
        dismissedTarget = nil
        lastRun = nil
        keyTap?.remove()
        hotkey?.remove()
        presenter.hideAll()
    }
}

/// One rewrite run as Retry and the refinements need it again: the action, the text it reshaped (nil:
/// the user's selection), and the tone a refinement keeps.
private struct RewriteRun {
    let action: RewriteAction
    let draft: String?
    let tone: RewriteAction?
}

/// The narrow surface the coordinator needs from the popup panel. `SelectionRewritePanelController`
/// conforms; tests substitute a stub that records calls. `@MainActor` because the panel is AppKit.
@MainActor protocol SelectionRewritePresenting: AnyObject {
    var isPopupKey: Bool { get }
    func showButton(caretRect: CGRect, fieldFrame: CGRect?, onPress: @escaping () -> Void)
    /// `takesKeyboard` is true for a popup the user opened (it needs typing and Return) and false for a
    /// notice, which must not swallow the user's keystrokes while it is on screen.
    func showPopup(near anchor: CGRect, model: SelectionRewritePopupModel, takesKeyboard: Bool)
    func refit()
    func hideAll()
}
extension SelectionRewritePanelController: SelectionRewritePresenting {}

/// Writes a rewrite into the host and reads back the field. A protocol so tests can record the
/// paste, the clipboard write and the selection restore without touching the pasteboard or AX.
@MainActor protocol SelectionRewriteTextOutput: AnyObject {
    func paste(_ text: String) -> Bool
    func copyToClipboard(_ text: String)
    func restoreSelection(_ range: NSRange, pid: pid_t) -> Bool
    func activate(pid: pid_t)
}

/// The rewrite engine as the coordinator sees it: the provider facts for the popup disclosure, and
/// one generation. Narrower than `RewriteEngine` so tests need no providers.
@MainActor protocol SelectionRewriteRunning: AnyObject {
    var activeProviderSendsOffDevice: Bool { get }
    var activeHostName: String? { get }
    func rewrite(_ request: RewriteRequest, onPartial: @escaping @MainActor (String) -> Void) async throws -> String
}

extension RewriteEngine: SelectionRewriteRunning {
    var activeProviderSendsOffDevice: Bool { activeProvider.sendsOffDevice }
    var activeHostName: String? { (activeProvider as? APIRewriteProvider)?.hostName }
}

/// Writes a rewrite into the host: pastes over the live selection (paste, not keystrokes, because a
/// typed line break would send a chat message), or puts it on the clipboard.
@MainActor
final class LiveSelectionRewriteTextOutput: SelectionRewriteTextOutput {
    private let inserter: SuggestionInserter
    init(inserter: SuggestionInserter) { self.inserter = inserter }
    nonisolated deinit {}
    func paste(_ text: String) -> Bool { inserter.pasteAtCaret(text) }
    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    func restoreSelection(_ range: NSRange, pid: pid_t) -> Bool { AXHelper.setSelectedTextRange(range, onFocusedElementOf: pid) }
    func activate(pid: pid_t) { NSRunningApplication(processIdentifier: pid)?.activate() }
}
