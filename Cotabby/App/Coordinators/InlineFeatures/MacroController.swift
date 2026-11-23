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
    private let inputMonitor: any InlineCommandInputIntercepting
    private let inserter: any InlineCommandTextInserting
    private let isEnabled: () -> Bool
    private let acceptKeyLabel: () -> String?

    /// Invoked whenever the capture state changes (open or teardown), so the coordinator can recompute
    /// whether the active accept tap should be installed. Teardown can happen outside an `observe`
    /// pass (focus change, long pause, click-away), so this notification is how the coordinator stays
    /// in sync without polling.
    var onCaptureStateChanged: (() -> Void)?

    /// The open capture, or `nil` while idle. Set when a `/` opens against a triggerable field and
    /// cleared by `teardownCapture()`, so it tracks `machine.isCapturing` except inside one
    /// `observe(_:)` pass, between the machine's own transition and `applyActions(_:)` catching up.
    private var capture: MacroCaptureSession?
    private var pendingDecision: InlineCaptureKeyDecision?
    private let idleTimer = InlineCaptureIdleTimer()
    private var cancellables = Set<AnyCancellable>()

    var isCapturing: Bool { machine.isCapturing }

    init(
        engine: MacroEngine,
        panel: any InlinePreviewPresenting,
        focusModel: any SuggestionFocusProviding,
        inputMonitor: any InlineCommandInputIntercepting,
        inserter: any InlineCommandTextInserting,
        isEnabled: @escaping () -> Bool,
        acceptKeyLabel: @escaping () -> String?
    ) {
        self.engine = engine
        self.panel = panel
        self.focusModel = focusModel
        self.inputMonitor = inputMonitor
        self.inserter = inserter
        self.isEnabled = isEnabled
        self.acceptKeyLabel = acceptKeyLabel
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
        let output = machine.reduce(triggerInput(for: event), hasInsertableResult: capture?.result != nil)
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
        switch InlineCommandKeyClassifier.classify(event, isWordAcceptKey: { inputMonitor.isWordAcceptKey($0) }) {
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
        capture = MacroCaptureSession(
            focusChangeSequence: context.focusChangeSequence,
            caretRect: context.caretRect
        )
        armIdleTimer()
        onCaptureStateChanged?()
    }

    private func updateQuery(_ query: String) {
        guard machine.isCapturing, var session = capture else { return }
        session.setResult(engine.evaluate(query), for: query)
        capture = session
        presentOrHide(session)
        armIdleTimer()
    }

    /// The preview only exists while the query evaluates to something; an incomplete or invalid
    /// query shows nothing rather than a stale result.
    private func presentOrHide(_ session: MacroCaptureSession) {
        guard let result = session.result else {
            panel.hide()
            return
        }
        panel.show(previewText: result.previewText, caretRect: session.caretRect, acceptKeyLabel: acceptKeyLabel())
    }

    /// Replaces the typed `/query` run with the result's insertion text. The delete count is the
    /// exact tracked run (the `/` sigil plus the observed query), so trailing field text is never
    /// touched. Posted on the next runloop tick so the synthetic burst is never re-entrant from
    /// inside the key's own tap callback.
    ///
    /// The insertion target is taken before the hop, from the field the capture ran in, for the same
    /// reason as the emoji picker: read afterwards, it would follow focus to wherever it went.
    private func commitIfPossible() {
        guard let session = capture, let result = session.result, let context = focusModel.snapshot.context else {
            teardownCapture()
            return
        }
        let deleteCount = session.typedRunUTF16Count
        let insertion = result.insertionText
        let target = InsertionTarget(snapshot: context)
        CotabbyLogger.suggestion.debug("macro commit deleteUTF16=\(deleteCount) query=\"\(session.query)\"")
        teardownCapture()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            _ = self.inserter.replace(deletingUTF16Count: deleteCount, with: insertion, in: target)
            self.focusModel.refreshNow()
        }
    }

    private func teardownCapture() {
        let wasActive = machine.isCapturing
        machine.reset()
        capture = nil
        pendingDecision = nil
        idleTimer.cancel()
        panel.hide()
        if wasActive {
            onCaptureStateChanged?()
        }
    }

    // MARK: - Focus and gating

    private func handleFocusSnapshot(_ snapshot: FocusSnapshot) {
        guard machine.isCapturing, var session = capture else { return }
        guard let context = InlineCaptureFocusGate.continuingContext(
            in: snapshot,
            focusChangeSequence: session.focusChangeSequence
        ) else {
            teardownCapture()
            return
        }
        session.caretRect = context.caretRect
        capture = session
        presentOrHide(session)
    }

    private func armIdleTimer() {
        idleTimer.arm { [weak self] in self?.teardownCapture() }
    }
}
