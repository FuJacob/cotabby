import Combine
import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Orchestrates the inline `:emoji:` picker. It is a sibling to `SuggestionCoordinator`, not part of
/// it: the two interactions are orthogonal (ghost-text prediction vs. a selectable emoji panel), and
/// keeping them separate stops the suggestion state machine from growing emoji concerns.
///
/// Data flow:
/// - `observe(_:)` receives every keystroke (via `SuggestionCoordinator.emojiInputObserver`) and feeds
///   the pure `EmojiTriggerStateMachine`. It records the per-key consume decision for the decider.
/// - `decideCaptureKey(_:)` is the closure the active tap consults to swallow navigation/commit/Escape
///   keys. It returns the decision `observe(_:)` just computed for the same event.
/// - Focus snapshots reposition the panel as the caret moves and cancel capture on focus change.
/// - On commit, the literal `:query` run is measured from Accessibility and replaced with the glyph.
@MainActor
final class EmojiPickerController {
    private var machine = EmojiTriggerStateMachine()
    private let matcher: EmojiMatcher
    private let panel: any EmojiPickerPanelPresenting
    private let focusModel: any SuggestionFocusProviding
    private let inputMonitor: any EmojiInputIntercepting
    private let inserter: any EmojiTextInserting
    private let isEnabled: () -> Bool
    /// Live emoji-customization preferences (skin tone / gender / neutral variant), read at match time.
    private let emojiPreferences: () -> EmojiVariantPreferences
    /// The accept-word key label shown as a keycap on the highlighted row; `nil` hides the hint.
    private let acceptKeyLabel: () -> String?

    private var currentQuery = ""
    private var matches: [EmojiMatch] = []
    private var selectedIndex = 0
    private var captureFocusSequence: UInt64?
    private var lastCaretRect: CGRect?
    private var pendingDecision: PendingDecision?
    private var longPauseTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// The consume decision `observe(_:)` computed for one key, read back by `decideCaptureKey(_:)`
    /// during the same event. The key code guards against a stale decision being applied to a later
    /// key if the decider is ever called without a preceding observer pass.
    private struct PendingDecision {
        let keyCode: CGKeyCode
        let consume: Bool
    }

    /// How long a capture may sit untouched before it self-cancels, so a panel never lingers if the
    /// user walks away mid-query (EMOJI.md §2.2). Generous because the user may pause to read matches.
    private static let longPauseNanoseconds: UInt64 = 8_000_000_000

    init(
        matcher: EmojiMatcher,
        panel: any EmojiPickerPanelPresenting,
        focusModel: any SuggestionFocusProviding,
        inputMonitor: any EmojiInputIntercepting,
        inserter: any EmojiTextInserting,
        isEnabled: @escaping () -> Bool,
        emojiPreferences: @escaping () -> EmojiVariantPreferences,
        acceptKeyLabel: @escaping () -> String?
    ) {
        self.matcher = matcher
        self.panel = panel
        self.focusModel = focusModel
        self.inputMonitor = inputMonitor
        self.inserter = inserter
        self.isEnabled = isEnabled
        self.emojiPreferences = emojiPreferences
        self.acceptKeyLabel = acceptKeyLabel
    }

    func start() {
        inputMonitor.emojiCaptureKeyDecider = { [weak self] keyEvent in
            self?.decideCaptureKey(keyEvent) ?? .notHandled
        }
        panel.onSelectIndex = { [weak self] index in
            guard let self else { return }
            self.selectedIndex = index
            self.commitSelectedMatch()
        }
        panel.onClickOutside = { [weak self] in
            self?.cancelCapture()
        }
        focusModel.snapshotPublisher
            .sink { [weak self] snapshot in self?.handleFocusSnapshot(snapshot) }
            .store(in: &cancellables)
    }

    func stop() {
        cancelCapture()
        inputMonitor.emojiCaptureKeyDecider = nil
        cancellables.removeAll()
    }

    // MARK: - Keystroke observation

    /// Drives the trigger state machine from the observer keystroke stream. Returns whether an emoji
    /// capture was involved with this key, so the suggestion coordinator can stand down. Consumption
    /// is recorded in `pendingDecision` for the active tap's decider (the listen-only observer here
    /// cannot consume).
    @discardableResult
    func observe(_ event: CapturedInputEvent) -> Bool {
        guard isEnabled() else {
            if machine.isCapturing { cancelCapture() }
            pendingDecision = nil
            return false
        }

        let wasCapturing = machine.isCapturing
        let output = machine.reduce(triggerInput(for: event), selectableMatchCount: matches.count)
        applyActions(output.actions)

        // The feature was involved if we were capturing before this key (covers commit/cancel that
        // just returned to idle) or are capturing after it (covers the opening `:`). Computed after
        // `applyActions` so an aborted open (secure field) correctly reports uninvolved. When involved,
        // `pendingDecision` carries the consume decision for the active tap; otherwise it is cleared so
        // the decider falls through to the suggestion accept path.
        let involved = wasCapturing || machine.isCapturing
        pendingDecision = involved ? PendingDecision(keyCode: event.keyCode, consume: output.consumesKey) : nil
        return involved
    }

    /// Per-key consume decision for the active tap. Returns the decision computed by the matching
    /// observer pass, or `.notHandled` when no capture is involved so suggestion acceptance proceeds.
    func decideCaptureKey(_ keyEvent: InputMonitorKeyEvent) -> InputMonitorAcceptTapDecision {
        guard let pending = pendingDecision, pending.keyCode == keyEvent.keyCode else {
            return .notHandled
        }
        pendingDecision = nil
        return pending.consume ? .consume : .passThrough
    }

    /// Translates a captured event into the machine's small input vocabulary. Mapping every key
    /// (even when idle) keeps the machine's boundary tracking accurate; the machine itself decides
    /// what matters in each state.
    private func triggerInput(for event: CapturedInputEvent) -> EmojiTriggerInput {
        let modifiers = ShortcutModifierMask(eventFlags: event.flags)
        if modifiers.contains(.command) || modifiers.contains(.control) {
            return .dismissExternally
        }

        // Commit only on the user's configured word-accept binding (keyCode + modifiers), matched the
        // same way the suggestion accept path matches it, so the picker stays consistent with
        // accepting a word. Checked before the keyCode switch so a rebind wins (Tab by default), and
        // so Return is no longer a commit key.
        if inputMonitor.isWordAcceptKey(InputMonitorKeyEvent(keyCode: event.keyCode, flags: event.flags)) {
            return .commitKey
        }

        switch event.keyCode {
        case 53:
            return .escape
        case 36, 76:                      // Return, Keypad Enter: dismiss and pass through, never commit
            return .dismissExternally
        case 126:
            return .navigate(.up)
        case 125:
            return .navigate(.down)
        case 123, 124, 117:               // Left, Right, Forward-Delete: caret moved, end capture
            return .dismissExternally
        case 51:
            // Option + Backspace deletes a whole word, which the single-character query model can't
            // track, so treat it as a dismissal rather than a one-character backspace. (Command +
            // Backspace is already handled by the modifier check above.)
            return modifiers.contains(.option) ? .dismissExternally : .backspace
        default:
            break
        }

        let characters = event.characters
        if characters.count == 1, let character = characters.first, !character.isNewline {
            return .character(character)
        }
        // Empty or multi-character keydowns (dead keys, IME) only matter as a cancel while capturing.
        return .dismissExternally
    }

    private func applyActions(_ actions: [EmojiTriggerAction]) {
        for action in actions {
            switch action {
            case let .open(query):
                beginCapture(query: query)
            case let .updateQuery(query):
                updateQuery(query)
            case let .moveSelection(move):
                moveSelection(move)
            case let .commit(mode):
                commit(mode)
            case .cancel:
                cancelCapture()
            }
        }
    }

    // MARK: - Capture lifecycle

    private func beginCapture(query: String) {
        guard canTrigger(), let context = focusModel.snapshot.context else {
            // A `:` opened the trigger but the field is unsupported/secure or its AX context has not
            // resolved yet (AX is eventually consistent right after a focus change). Aborting here
            // looks to the user like "the picker did nothing on the first try"; log it so that
            // first-keystroke failure is distinguishable from a commit-path failure.
            CotabbyLogger.suggestion.debug("emoji capture aborted at open: no triggerable focus context")
            machine.reset()
            return
        }
        captureFocusSequence = context.focusChangeSequence
        lastCaretRect = context.caretRect
        inputMonitor.setCaptureInterceptionActive(true)
        refreshMatches(query: query)
        presentPanel()
        armLongPauseTimer()
        CotabbyLogger.suggestion.debug("emoji capture opened query=\"\(query)\" matches=\(matches.count)")
    }

    private func updateQuery(_ query: String) {
        guard machine.isCapturing else { return }
        refreshMatches(query: query)
        // Reposition because the match count (and therefore the panel height) may have changed.
        presentPanel()
        armLongPauseTimer()
    }

    private func moveSelection(_ move: EmojiSelectionMove) {
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

    private func commit(_ mode: EmojiCommitMode) {
        switch mode {
        case .key:
            commitSelectedMatch()
        case .closingColon:
            commitClosingColon()
        }
    }

    /// Mode A: a consumed Tab/Return, or a row click. The field holds `:query`, so delete that run and
    /// insert the highlighted glyph.
    private func commitSelectedMatch() {
        guard selectedIndex >= 0, selectedIndex < matches.count else {
            CotabbyLogger.suggestion.debug("emoji commit (key) skipped: no selectable match query=\"\(currentQuery)\"")
            cancelCapture()
            return
        }
        let glyph = matches[selectedIndex].glyph
        let fallback = currentQuery.utf16.count + 1   // ":" + query
        CotabbyLogger.suggestion.debug("emoji commit (key) glyph=\(glyph) query=\"\(currentQuery)\"")
        teardownCapture()
        scheduleReplaceEmojiQuery(with: glyph, fallbackUTF16: fallback)
    }

    /// Mode B: the passed-through closing `:`. The field will hold `:query:` once the colon lands, so
    /// defer one runloop tick, then measure and replace the whole run (EMOJI.md §3.2, §5.5).
    private func commitClosingColon() {
        let query = currentQuery
        let glyph = bestGlyphForClosingColon(query: query)
        let fallback = query.utf16.count + 2   // ":" + query + ":"
        teardownCapture()
        guard let glyph else { return }   // no match: leave the literal ":query:" untouched
        scheduleReplaceEmojiQuery(with: glyph, fallbackUTF16: fallback)
    }

    private func cancelCapture() {
        teardownCapture()
    }

    private func teardownCapture() {
        machine.reset()
        matches = []
        selectedIndex = 0
        currentQuery = ""
        captureFocusSequence = nil
        lastCaretRect = nil
        pendingDecision = nil
        longPauseTask?.cancel()
        longPauseTask = nil
        inputMonitor.setCaptureInterceptionActive(false)
        panel.hide()
    }

    // MARK: - Matching and presentation

    private func refreshMatches(query: String) {
        currentQuery = query
        matches = EmojiVariantResolver.resolve(matcher.matches(for: query), preferences: emojiPreferences())
        selectedIndex = 0
    }

    private func presentPanel() {
        let caretRect = lastCaretRect ?? focusModel.snapshot.context?.caretRect ?? .zero
        panel.show(
            query: currentQuery,
            matches: matches,
            selectedIndex: selectedIndex,
            caretRect: caretRect,
            acceptKeyLabel: acceptKeyLabel()
        )
    }

    private func bestGlyphForClosingColon(query: String) -> String? {
        let lowercased = query.lowercased()
        let results = EmojiVariantResolver.resolve(matcher.matches(for: query), preferences: emojiPreferences())
        if let exact = results.first(where: { $0.entry.aliases.contains(lowercased) }) {
            return exact.glyph
        }
        return results.first?.glyph
    }

    /// Posts the delete+glyph replace on the next runloop tick. Both commit modes defer through here
    /// so the synthetic events are never posted re-entrantly from inside the keystroke's own tap
    /// callback (EMOJI.md §4.4, §5.5). Posting them synchronously from the observer pass was the
    /// source of the flaky "panel vanished but no emoji landed" Enter/Tab commits; deferring also
    /// lets the field settle before we measure the run to delete.
    private func scheduleReplaceEmojiQuery(with glyph: String, fallbackUTF16: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.replaceEmojiQuery(with: glyph, fallbackUTF16: fallbackUTF16)
        }
    }

    private func replaceEmojiQuery(with glyph: String, fallbackUTF16: Int) {
        // Measure the literal run from the field and replace it. `trailingRunUTF16Length` returns nil
        // when the field no longer ends in a `:query` run, so we fall back to the known typed length;
        // that nil-check is what keeps a stray commit from deleting unrelated text. We deliberately do
        // NOT force a fresh AX resolve + `focusChangeSequence` guard here: the resolve re-stamped the
        // sequence and made the guard abort legitimate commits (the panel vanished with no emoji).
        let preceding = focusModel.snapshot.context?.precedingText ?? ""
        let measured = EmojiQueryRun.trailingRunUTF16Length(in: preceding)
        let deleteCount = measured ?? fallbackUTF16
        CotabbyLogger.suggestion.debug(
            "emoji replace glyph=\(glyph) deleteUTF16=\(deleteCount) measured=\(measured != nil)"
        )
        _ = inserter.replace(deletingUTF16Count: deleteCount, with: glyph)
        // Let the focus pipeline re-read the field so any pending suggestion uses the post-insertion
        // text instead of the stale `:query` we just removed.
        focusModel.refreshNow()
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
            // The field changed (or went secure) under an open capture. This is the other common
            // "panel vanished mid-query" cause, so record it distinctly from a user cancel.
            CotabbyLogger.suggestion.debug("emoji capture cancelled: focus changed during capture")
            cancelCapture()
            return
        }
        // Follow the caret as the user types the query.
        lastCaretRect = context.caretRect
        panel.show(
            query: currentQuery,
            matches: matches,
            selectedIndex: selectedIndex,
            caretRect: context.caretRect,
            acceptKeyLabel: acceptKeyLabel()
        )
    }

    private func armLongPauseTimer() {
        longPauseTask?.cancel()
        longPauseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: EmojiPickerController.longPauseNanoseconds)
            guard !Task.isCancelled else { return }
            self?.cancelCapture()
        }
    }
}
