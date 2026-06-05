import Combine
import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Orchestrates the inline `/cb` clipboard history picker. A sibling to the emoji and macro
/// controllers, it shares their keystroke-observation contract so the `InlineCommandCoordinator` can
/// route the single accept-tap decider to whichever capture is open.
///
/// `/cb` is a two-stage command driven by a pure `ClipboardCommandTriggerStateMachine`:
///  1. Typing `/cb` at a word boundary shows a compact one-row "Open Clipboard History" affordance
///     (the hint) near the caret.
///  2. The accept key (Tab by default) escalates that affordance into the full history list, where
///     arrows navigate and the accept key (or a click) inserts the chosen clip, replacing the typed
///     `/cb` run. Multi-line clips route through the inserter's paste path so a clip with newlines
///     never submits the message in chat apps.
///
/// Because `/` overlaps the macro trigger, the machine stays passive until `/cb` is fully matched and
/// the coordinator offers this participant before the macro one, so the accept key routes here.
@MainActor
final class ClipboardPickerController {
    private var machine = ClipboardCommandTriggerStateMachine()
    private let history: ClipboardHistoryService
    private let panel: any CommandPickerPresenting
    private let focusModel: any SuggestionFocusProviding
    private let inserter: any EmojiTextInserting
    private let isEnabled: () -> Bool
    private let acceptKeyLabel: () -> String?
    private let isWordAcceptKey: (InputMonitorKeyEvent) -> Bool

    var onCaptureStateChanged: (() -> Void)?

    private enum Stage { case hint, list }
    private var stage: Stage = .hint
    private var matches: [ClipboardItem] = []
    private var selectedIndex = 0
    private var captureFocusSequence: UInt64?
    private var lastCaretRect: CGRect?
    private var pendingDecision: PendingDecision?
    private var longPauseTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private struct PendingDecision {
        let keyCode: CGKeyCode
        let consume: Bool
    }

    /// UTF-16 length of the literal `/cb` command run a committed clip replaces. The accept key that
    /// opens the list is consumed (never typed), and there is no in-list filtering, so the tracked run
    /// is always exactly the command.
    private static let commandRunUTF16 = 3   // "/cb"

    private static let longPauseNanoseconds: UInt64 = 8_000_000_000

    var isCapturing: Bool { machine.isCapturing }

    init(
        history: ClipboardHistoryService,
        panel: any CommandPickerPresenting,
        focusModel: any SuggestionFocusProviding,
        inserter: any EmojiTextInserting,
        isEnabled: @escaping () -> Bool,
        acceptKeyLabel: @escaping () -> String?,
        isWordAcceptKey: @escaping (InputMonitorKeyEvent) -> Bool
    ) {
        self.history = history
        self.panel = panel
        self.focusModel = focusModel
        self.inserter = inserter
        self.isEnabled = isEnabled
        self.acceptKeyLabel = acceptKeyLabel
        self.isWordAcceptKey = isWordAcceptKey
    }

    func start() {
        panel.onSelectIndex = { [weak self] index in self?.handleRowClicked(index) }
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
        let output = machine.reduce(triggerInput(for: event), selectableCount: matches.count)
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

    private func triggerInput(for event: CapturedInputEvent) -> ClipboardCommandInput {
        let modifiers = ShortcutModifierMask(eventFlags: event.flags)
        if modifiers.contains(.command) || modifiers.contains(.control) {
            return .dismissExternally
        }
        if isWordAcceptKey(InputMonitorKeyEvent(keyCode: event.keyCode, flags: event.flags)) {
            return .commitKey
        }

        switch event.keyCode {
        case 53:
            return .escape
        case 36, 76:                      // Return, Keypad Enter
            return .dismissExternally
        case 126:
            return .navigate(.up)
        case 125:
            return .navigate(.down)
        case 123, 124, 117:               // Left, Right, Forward-Delete: caret moved, end capture
            return .dismissExternally
        case 51:
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

    private func applyActions(_ actions: [ClipboardCommandAction]) {
        for action in actions {
            switch action {
            case .openHint:
                beginHint()
            case .openList:
                openList()
            case let .moveSelection(move):
                moveSelection(move)
            case .commit:
                commitSelected()
            case .cancel:
                cancelCapture()
            }
        }
    }

    // MARK: - Capture lifecycle

    private func beginHint() {
        guard canTrigger(), let context = focusModel.snapshot.context else {
            // `/cb` matched but the field is unsupported/secure or its AX context has not resolved yet
            // (AX is eventually consistent right after a focus change). Log so a first-keystroke
            // failure is distinguishable from a commit-path failure.
            CotabbyLogger.suggestion.debug("clipboard capture aborted at open: no triggerable focus context")
            machine.reset()
            return
        }
        captureFocusSequence = context.focusChangeSequence
        lastCaretRect = context.caretRect
        stage = .hint
        matches = []
        selectedIndex = 0
        presentCurrentStage()
        armLongPauseTimer()
        onCaptureStateChanged?()
        CotabbyLogger.suggestion.debug("clipboard hint opened")
    }

    private func openList() {
        guard machine.isCapturing else { return }
        stage = .list
        matches = history.items
        selectedIndex = 0
        presentCurrentStage()
        armLongPauseTimer()
        CotabbyLogger.suggestion.debug("clipboard list opened items=\(matches.count)")
    }

    private func moveSelection(_ move: CommandSelectionMove) {
        guard !matches.isEmpty else { return }
        switch move {
        case .up:
            selectedIndex = (selectedIndex - 1 + matches.count) % matches.count
        case .down:
            selectedIndex = (selectedIndex + 1) % matches.count
        }
        panel.setSelectedIndex(selectedIndex)
        armLongPauseTimer()
    }

    private func presentCurrentStage() {
        let caretRect = lastCaretRect ?? focusModel.snapshot.context?.caretRect ?? .zero
        switch stage {
        case .hint:
            let row = CommandRow(
                id: "open-clipboard",
                leading: .symbol("doc.on.clipboard"),
                title: "Open Clipboard History"
            )
            panel.show(
                rows: [row],
                headerText: "/cb",
                selectedIndex: 0,
                caretRect: caretRect,
                acceptKeyLabel: acceptKeyLabel()
            )
        case .list:
            let rows = matches.map { item in
                CommandRow(
                    id: item.id.uuidString,
                    leading: .symbol("doc.on.clipboard"),
                    title: item.preview,
                    subtitle: item.sourceApp
                )
            }
            panel.show(
                rows: rows,
                headerText: "Clipboard History",
                selectedIndex: selectedIndex,
                caretRect: caretRect,
                acceptKeyLabel: acceptKeyLabel()
            )
        }
    }

    /// A click on a row: in the hint stage it opens the list (mirroring the accept key); in the list
    /// stage it inserts the clicked clip. Routed through the machine for the hint so the lifecycle
    /// stays in one place.
    private func handleRowClicked(_ index: Int) {
        switch stage {
        case .hint:
            applyActions(machine.reduce(.commitKey, selectableCount: 0).actions)
        case .list:
            selectedIndex = index
            commitSelected()
        }
    }

    /// Replaces the typed `/cb` run with the chosen clip. Multi-line clips route through the inserter's
    /// paste path so a clip with newlines does not submit the message in chat apps. Posted on the next
    /// runloop tick so the synthetic burst is never re-entrant from inside the key's own tap callback.
    private func commitSelected() {
        guard stage == .list, selectedIndex >= 0, selectedIndex < matches.count else {
            cancelCapture()
            return
        }
        let text = matches[selectedIndex].text
        let deleteCount = Self.commandRunUTF16
        CotabbyLogger.suggestion.debug("clipboard commit deleteUTF16=\(deleteCount)")
        teardownCapture()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            _ = self.inserter.replace(deletingUTF16Count: deleteCount, with: text)
            self.focusModel.refreshNow()
        }
    }

    private func cancelCapture() {
        teardownCapture()
    }

    private func teardownCapture() {
        let wasCapturing = machine.isCapturing
        machine.reset()
        stage = .hint
        matches = []
        selectedIndex = 0
        captureFocusSequence = nil
        lastCaretRect = nil
        pendingDecision = nil
        longPauseTask?.cancel()
        longPauseTask = nil
        panel.hide()
        if wasCapturing {
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
        presentCurrentStage()
    }

    private func armLongPauseTimer() {
        longPauseTask?.cancel()
        longPauseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ClipboardPickerController.longPauseNanoseconds)
            guard !Task.isCancelled else { return }
            self?.cancelCapture()
        }
    }
}
