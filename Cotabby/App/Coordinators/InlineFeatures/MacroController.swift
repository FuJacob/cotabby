import Combine
import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Orchestrates the inline `/macro` preview. It is a sibling to `EmojiPickerController` and shares
/// the same shape: a pure `MacroTriggerStateMachine` drives the capture lifecycle, the controller
/// evaluates the live query through `MacroEngine`, presents a single-row preview near the caret, and
/// on accept replaces the typed `/query` run with the result.
///
/// It deliberately mirrors the emoji controller's keystroke-observation contract (`observe` records a
/// per-key consume decision that `decideCaptureKey` reads back for the same key) so the shared
/// `InlineCommandCoordinator` can route the single accept-tap decider to whichever capture is open.
@MainActor
final class MacroController {
    private var machine = MacroTriggerStateMachine()
    private let engine: MacroEngine
    private let panel: any InlinePreviewPresenting
    private let focusModel: any SuggestionFocusProviding
    private let inserter: any EmojiTextInserting
    private let isEnabled: () -> Bool
    private let acceptKeyLabel: () -> String?
    private let isWordAcceptKey: (InputMonitorKeyEvent) -> Bool

    /// Invoked whenever the capture state changes (open or teardown), so the coordinator can recompute
    /// whether the active accept tap should be installed. Teardown can happen outside an `observe`
    /// pass (focus change, long pause, click-away), so this notification is how the coordinator stays
    /// in sync without polling.
    var onCaptureStateChanged: (() -> Void)?

    private var currentQuery = ""
    private var currentResult: MacroResult?
    private var captureFocusSequence: UInt64?
    private var lastCaretRect: CGRect?
    private var pendingDecision: InlineCaptureKeyDecision?
    private let idleTimer = InlineCaptureIdleTimer()
    private var cancellables = Set<AnyCancellable>()

    var isCapturing: Bool { machine.isCapturing }

    init(
        engine: MacroEngine,
        panel: any InlinePreviewPresenting,
        focusModel: any SuggestionFocusProviding,
        inserter: any EmojiTextInserting,
        isEnabled: @escaping () -> Bool,
        acceptKeyLabel: @escaping () -> String?,
        isWordAcceptKey: @escaping (InputMonitorKeyEvent) -> Bool
    ) {
        self.engine = engine
        self.panel = panel
        self.focusModel = focusModel
        self.inserter = inserter
        self.isEnabled = isEnabled
        self.acceptKeyLabel = acceptKeyLabel
        self.isWordAcceptKey = isWordAcceptKey
    }

    func start() {
        panel.onClick = { [weak self] in self?.commitIfPossible() }
        panel.onClickOutside = { [weak self] in self?.teardownCapture() }
        focusModel.snapshotPublisher
            .sink { [weak self] snapshot in self?.handleFocusSnapshot(snapshot) }
            .store(in: &cancellables)
    }

    func stop() {
        teardownCapture()
        cancellables.removeAll()
    }

    // MARK: - Keystroke observation

    @discardableResult
    func observe(_ event: CapturedInputEvent) -> Bool {
        guard isEnabled() else {
            if machine.isCapturing { teardownCapture() }
            pendingDecision = nil
            return false
        }

        let wasCapturing = machine.isCapturing
        let output = machine.reduce(triggerInput(for: event), hasInsertableResult: currentResult != nil)
        applyActions(output.actions)

        let involved = wasCapturing || machine.isCapturing
        pendingDecision = involved ? InlineCaptureKeyDecision(keyCode: event.keyCode, consume: output.consumesKey) : nil
        return involved
    }

    func decideCaptureKey(_ keyEvent: InputMonitorKeyEvent) -> InputMonitorAcceptTapDecision {
        guard let decision = pendingDecision?.tapDecision(for: keyEvent) else {
            return .notHandled
        }
        pendingDecision = nil
        return decision
    }

    private func triggerInput(for event: CapturedInputEvent) -> MacroTriggerInput {
        // Commit on the user's configured word-accept binding, so the macro commit stays consistent
        // with accepting a suggestion word.
        switch InlineCommandKeyClassifier.classify(event, isWordAcceptKey: isWordAcceptKey) {
        case let .character(character):
            return .character(character)
        case .backspace:
            return .backspace
        case .commitKey:
            return .commitKey
        case .escape:
            return .escape
        case .arrow:
            // The preview has nothing to navigate, so an arrow means the caret left the query.
            return .navigate
        case .dismissExternally:
            return .dismissExternally
        }
    }

    private func applyActions(_ actions: [MacroTriggerAction]) {
        for action in actions {
            switch action {
            case .open:
                beginCapture()
            case let .updateQuery(query):
                updateQuery(query)
            case .commit:
                commitIfPossible()
            case .cancel:
                teardownCapture()
            }
        }
    }

    // MARK: - Capture lifecycle

    private func beginCapture() {
        guard let context = InlineCaptureFocusGate.triggerableContext(in: focusModel.snapshot) else {
            // A `/` opened the trigger but the field is unsupported/secure or its AX context has not
            // resolved yet (AX is eventually consistent right after a focus change). Aborting here is
            // what looks to the user like "the macro preview sometimes does nothing"; log it so a
            // first-keystroke failure is distinguishable from a commit-path failure.
            CotabbyLogger.suggestion.debug("macro capture aborted at open: no triggerable focus context")
            machine.reset()
            return
        }
        captureFocusSequence = context.focusChangeSequence
        lastCaretRect = context.caretRect
        currentQuery = ""
        currentResult = nil
        armIdleTimer()
        onCaptureStateChanged?()
    }

    private func updateQuery(_ query: String) {
        guard machine.isCapturing else { return }
        currentQuery = query
        currentResult = engine.evaluate(query)
        presentOrHide()
        armIdleTimer()
    }

    private func presentOrHide() {
        guard let result = currentResult else {
            panel.hide()
            return
        }
        let caretRect = lastCaretRect ?? focusModel.snapshot.context?.caretRect ?? .zero
        panel.show(previewText: result.previewText, caretRect: caretRect, acceptKeyLabel: acceptKeyLabel())
    }

    /// Replaces the typed `/query` run with the result's insertion text. The delete count is the
    /// exact tracked run (the `/` sigil plus the observed query), so trailing field text is never
    /// touched. Posted on the next runloop tick so the synthetic burst is never re-entrant from
    /// inside the key's own tap callback.
    private func commitIfPossible() {
        guard let result = currentResult else {
            teardownCapture()
            return
        }
        let deleteCount = 1 + currentQuery.utf16.count   // "/" + query
        let insertion = result.insertionText
        CotabbyLogger.suggestion.debug("macro commit deleteUTF16=\(deleteCount) query=\"\(currentQuery)\"")
        teardownCapture()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            _ = self.inserter.replace(deletingUTF16Count: deleteCount, with: insertion)
            self.focusModel.refreshNow()
        }
    }

    private func teardownCapture() {
        let wasActive = machine.isCapturing
        machine.reset()
        currentQuery = ""
        currentResult = nil
        captureFocusSequence = nil
        lastCaretRect = nil
        pendingDecision = nil
        idleTimer.cancel()
        panel.hide()
        if wasActive {
            onCaptureStateChanged?()
        }
    }

    // MARK: - Focus and gating

    private func handleFocusSnapshot(_ snapshot: FocusSnapshot) {
        guard machine.isCapturing else { return }
        guard let context = InlineCaptureFocusGate.continuingContext(
            in: snapshot,
            focusChangeSequence: captureFocusSequence
        ) else {
            teardownCapture()
            return
        }
        lastCaretRect = context.caretRect
        presentOrHide()
    }

    private func armIdleTimer() {
        idleTimer.arm { [weak self] in self?.teardownCapture() }
    }
}
