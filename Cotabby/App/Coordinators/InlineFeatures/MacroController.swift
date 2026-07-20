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
    private var pendingDecision: PendingDecision?
    private var longPauseTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private struct PendingDecision {
        let keyCode: CGKeyCode
        let consume: Bool
    }

    /// How long a capture may sit untouched before it self-cancels, so a stray preview never lingers.
    private static let longPauseNanoseconds: UInt64 = 8_000_000_000

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
        panel.onClickOutside = { [weak self] in self?.cancelCapture() }
        focusModel.snapshotPublisher
            .sink { [weak self] snapshot in self?.handleFocusSnapshot(snapshot) }
            .store(in: &cancellables)
    }

    func stop() {
        cancelCapture()
        cancellables.removeAll()
    }

    // MARK: - Keystroke observation

    @discardableResult
    func observe(_ event: CapturedInputEvent) -> Bool {
        guard isEnabled() else {
            if machine.isCapturing { cancelCapture() }
            pendingDecision = nil
            return false
        }

        let wasCapturing = machine.isCapturing
        let output = machine.reduce(triggerInput(for: event), hasInsertableResult: currentResult != nil)
        applyActions(output.actions)

        let involved = wasCapturing || machine.isCapturing
        pendingDecision = involved ? PendingDecision(keyCode: event.keyCode, consume: output.consumesKey) : nil
        return involved
    }

    func decideCaptureKey(_ keyEvent: InputMonitorKeyEvent) -> InputMonitorAcceptTapDecision {
        guard let pending = pendingDecision, pending.keyCode == keyEvent.keyCode else {
            return .notHandled
        }
        pendingDecision = nil
        return pending.consume ? .consume : .passThrough
    }

    private func triggerInput(for event: CapturedInputEvent) -> MacroTriggerInput {
        let modifiers = ShortcutModifierMask(eventFlags: event.flags)
        if modifiers.contains(.command) || modifiers.contains(.control) {
            return .dismissExternally
        }

        // Commit on the user's configured word-accept binding, matched the same way the suggestion
        // accept path matches it, so the macro commit stays consistent with accepting a word.
        if isWordAcceptKey(InputMonitorKeyEvent(keyCode: event.keyCode, flags: event.flags)) {
            return .commitKey
        }

        switch event.keyCode {
        case 53:
            return .escape
        case 36, 76:                       // Return, Keypad Enter: dismiss and pass through
            return .dismissExternally
        case 123, 124, 125, 126:           // Arrows: caret moved, end capture
            return .navigate
        case 117:                          // Forward delete
            return .dismissExternally
        case 51:
            // Option + Backspace deletes a whole word, which the single-character query model can't
            // track, so treat it as a dismissal rather than a one-character backspace.
            return modifiers.contains(.option) ? .dismissExternally : .backspace
        default:
            break
        }

        let characters = event.characters
        if characters.count == 1, let character = characters.first, !character.isNewline {
            return .character(character)
        }
        return .dismissExternally
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
                cancelCapture()
            }
        }
    }

    // MARK: - Capture lifecycle

    private func beginCapture() {
        guard canTrigger(), let context = focusModel.snapshot.context else {
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
        armLongPauseTimer()
        onCaptureStateChanged?()
    }

    private func updateQuery(_ query: String) {
        guard machine.isCapturing else { return }
        currentQuery = query
        currentResult = engine.evaluate(query)
        presentOrHide()
        armLongPauseTimer()
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
            cancelCapture()
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

    private func cancelCapture() {
        teardownCapture()
    }

    private func teardownCapture() {
        let wasActive = machine.isCapturing
        machine.reset()
        currentQuery = ""
        currentResult = nil
        captureFocusSequence = nil
        lastCaretRect = nil
        pendingDecision = nil
        longPauseTask?.cancel()
        longPauseTask = nil
        panel.hide()
        if wasActive {
            onCaptureStateChanged?()
        }
    }

    // MARK: - Focus and gating

    private func canTrigger() -> Bool {
        let snapshot = focusModel.snapshot
        guard case .supported = snapshot.capability else { return false }
        guard let context = snapshot.context, !context.isSecure else { return false }
        return true
    }

    private func handleFocusSnapshot(_ snapshot: FocusSnapshot) {
        guard machine.isCapturing else { return }
        guard let context = snapshot.context,
              !context.isSecure,
              context.focusChangeSequence == captureFocusSequence else {
            cancelCapture()
            return
        }
        lastCaretRect = context.caretRect
        presentOrHide()
    }

    private func armLongPauseTimer() {
        longPauseTask?.cancel()
        longPauseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: MacroController.longPauseNanoseconds)
            guard !Task.isCancelled else { return }
            self?.cancelCapture()
        }
    }
}
