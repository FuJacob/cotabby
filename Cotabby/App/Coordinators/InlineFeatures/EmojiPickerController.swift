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
/// - `observe(_:)` receives every keystroke (via `SuggestionCoordinator.inlineCommandObserver`) and feeds
///   the pure `EmojiTriggerStateMachine`. It records the per-key consume decision for the decider.
/// - `decideCaptureKey(_:)` is the closure the active tap consults to swallow navigation/commit/Escape
///   keys. It returns the decision `observe(_:)` just computed for the same event.
/// - Focus snapshots reposition the panel as the caret moves and cancel capture on focus change.
/// - On commit, the literal `:query` run is measured from Accessibility and replaced with the glyph.
@MainActor
final class EmojiPickerController {
    private var machine = EmojiTriggerStateMachine()
    /// Built on first use rather than injected ready-made: the bundled catalog decode plus index
    /// costs a few MB of resident strings, and most sessions never open the picker. The one-time
    /// build lands on the first `:` capture's first match request, which is user-paced.
    private let matcherProvider: @MainActor () -> EmojiMatcher
    private var cachedMatcher: EmojiMatcher?
    private var matcher: EmojiMatcher {
        if let cachedMatcher {
            return cachedMatcher
        }
        let built = matcherProvider()
        cachedMatcher = built
        return built
    }
    private let panel: any EmojiPickerPanelPresenting
    private let focusModel: any SuggestionFocusProviding
    private let inputMonitor: any InlineCommandInputIntercepting
    private let inserter: any InlineCommandTextInserting
    private let isEnabled: () -> Bool
    /// Live emoji-customization preferences (skin tone / gender / neutral variant), read at match time.
    private let emojiPreferences: () -> EmojiVariantPreferences
    /// Live personal usage snapshot, read at match time to rank favorites and seed the bare-`:` panel.
    /// `@MainActor`: it reads main-actor `EmojiUsageStore` state, matching where the picker runs.
    private let emojiUsage: @MainActor () -> EmojiUsageSnapshot
    /// Records a committed emoji's primary alias so future ranking and recents reflect it.
    /// `@MainActor`: it mutates main-actor `EmojiUsageStore` state.
    private let recordEmojiUsage: @MainActor (String) -> Void

    /// The open capture, or `nil` while idle. Set when a `:` opens against a triggerable field and
    /// cleared by `teardownCapture()`, so it tracks `machine.isCapturing` except inside one
    /// `observe(_:)` pass, between the machine's own transition and `applyActions(_:)` catching up.
    private var capture: EmojiCaptureSession?
    private var pendingDecision: InlineCaptureKeyDecision?
    private let idleTimer = InlineCaptureIdleTimer()
    private var cancellables = Set<AnyCancellable>()

    /// Whether an emoji capture is currently open. Read by `InlineCommandCoordinator` to keep the
    /// input monitor's shared accept-tap interception in sync across the emoji and macro features.
    var isCapturing: Bool { machine.isCapturing }

    /// Invoked when capture opens or tears down, including teardown outside an `observe` pass (focus
    /// change, long pause, click-away), so the coordinator can recompute tap interception. The
    /// coordinator, not this controller, owns the input monitor's single interception flag.
    var onCaptureStateChanged: (() -> Void)?

    init(
        matcherProvider: @MainActor @escaping () -> EmojiMatcher,
        panel: any EmojiPickerPanelPresenting,
        focusModel: any SuggestionFocusProviding,
        inputMonitor: any InlineCommandInputIntercepting,
        inserter: any InlineCommandTextInserting,
        isEnabled: @escaping () -> Bool,
        emojiPreferences: @escaping () -> EmojiVariantPreferences,
        emojiUsage: @MainActor @escaping () -> EmojiUsageSnapshot,
        recordEmojiUsage: @MainActor @escaping (String) -> Void
    ) {
        self.matcherProvider = matcherProvider
        self.panel = panel
        self.focusModel = focusModel
        self.inputMonitor = inputMonitor
        self.inserter = inserter
        self.isEnabled = isEnabled
        self.emojiPreferences = emojiPreferences
        self.emojiUsage = emojiUsage
        self.recordEmojiUsage = recordEmojiUsage
    }

    func start() {
        // The accept-tap capture decider is a single slot shared with the macro feature, so
        // `InlineCommandCoordinator` installs it and routes to `decideCaptureKey(_:)`.
        panel.onSelectIndex = { [weak self] index in
            guard let self else { return }
            self.capture?.select(index: index)
            self.commitSelectedMatch()
        }
        panel.onClickOutside = { [weak self] in
            self?.teardownCapture()
        }
        focusModel.snapshotPublisher
            .sink { [weak self] snapshot in self?.handleFocusSnapshot(snapshot) }
            .store(in: &cancellables)
    }

    func stop() {
        teardownCapture()
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
            if machine.isCapturing { teardownCapture() }
            pendingDecision = nil
            return false
        }

        let wasCapturing = machine.isCapturing
        let output = machine.reduce(triggerInput(for: event), selectableMatchCount: capture?.matches.count ?? 0)
        applyActions(output.actions)

        // The feature was involved if we were capturing before this key (covers commit/cancel that
        // just returned to idle) or are capturing after it (covers the opening `:`). Computed after
        // `applyActions` so an aborted open (secure field) correctly reports uninvolved. When involved,
        // `pendingDecision` carries the consume decision for the active tap; otherwise it is cleared so
        // the decider falls through to the suggestion accept path.
        let involved = wasCapturing || machine.isCapturing
        pendingDecision = involved ? InlineCaptureKeyDecision(keyCode: event.keyCode, consume: output.consumesKey) : nil
        return involved
    }

    /// Per-key consume decision for the active tap. Returns the decision computed by the matching
    /// observer pass, or `.notHandled` when no capture is involved so suggestion acceptance proceeds.
    func decideCaptureKey(_ keyEvent: InputMonitorKeyEvent) -> InputMonitorAcceptTapDecision {
        guard let decision = pendingDecision?.tapDecision(for: keyEvent) else {
            return .notHandled
        }
        pendingDecision = nil
        return decision
    }

    /// Translates a captured event into the machine's small input vocabulary. Mapping every key
    /// (even when idle) keeps the machine's boundary tracking accurate; the machine itself decides
    /// what matters in each state.
    private func triggerInput(for event: CapturedInputEvent) -> EmojiTriggerInput {
        // Commit only on the user's configured word-accept binding, so the picker stays consistent
        // with accepting a suggestion word and follows a rebind (Tab by default).
        switch InlineCommandKeyClassifier.classify(event, isWordAcceptKey: { inputMonitor.isWordAcceptKey($0) }) {
        case let .character(character):
            return .character(character)
        case .backspace:
            return .backspace
        case .commitKey:
            return .commitKey
        case .escape:
            return .escape
        // The picker is a horizontal ribbon, so both arrow axes walk the same one-dimensional
        // match list. With no matches the state machine lets these pass through, so the caret
        // still moves.
        case .arrow(.up), .arrow(.left):
            return .navigate(.previous)
        case .arrow(.down), .arrow(.right):
            return .navigate(.next)
        case .dismissExternally:
            return .dismissExternally
        }
    }

    private func applyActions(_ actions: [EmojiTriggerAction]) {
        for action in actions {
            switch action {
            case .open:
                beginCapture()
            case let .updateQuery(query):
                updateQuery(query)
            case let .moveSelection(move):
                moveSelection(move)
            case let .commit(mode):
                commit(mode)
            case .cancel:
                teardownCapture()
            }
        }
    }

    // MARK: - Capture lifecycle

    private func beginCapture() {
        guard let context = InlineCaptureFocusGate.triggerableContext(in: focusModel.snapshot) else {
            // A `:` opened the trigger but the field is unsupported/secure or its AX context has not
            // resolved yet (AX is eventually consistent right after a focus change). Aborting here
            // looks to the user like "the picker did nothing on the first try"; log it so that
            // first-keystroke failure is distinguishable from a commit-path failure.
            CotabbyLogger.suggestion.debug("emoji capture aborted at open: no triggerable focus context")
            machine.reset()
            return
        }
        var session = EmojiCaptureSession(
            focusChangeSequence: context.focusChangeSequence,
            caretRect: context.caretRect
        )
        // A bare ":" opens with an empty query and immediately shows the user's recents/popular set.
        session.setResults(rankedMatches(for: ""), for: "")
        capture = session
        present(session)
        armIdleTimer()
        onCaptureStateChanged?()
        CotabbyLogger.suggestion.debug("emoji capture opened matches=\(session.matches.count)")
    }

    private func updateQuery(_ query: String) {
        guard machine.isCapturing, var session = capture else { return }
        session.setResults(rankedMatches(for: query), for: query)
        capture = session
        // Reposition because the match count (and therefore the panel width) may have changed.
        present(session)
        armIdleTimer()
    }

    private func moveSelection(_ move: EmojiSelectionMove) {
        guard var session = capture else { return }
        guard session.moveSelection(move) else { return }
        capture = session
        panel.setSelectedIndex(session.selectedIndex)
        armIdleTimer()
    }

    private func commit(_ mode: EmojiCommitMode) {
        switch mode {
        case .key:
            commitSelectedMatch()
        case .closingColon:
            commitClosingColon()
        }
    }

    /// The consumed word-accept key, or a click on a glyph. The field holds `:query`, so delete that
    /// run and insert the highlighted glyph.
    private func commitSelectedMatch() {
        guard let session = capture, let selected = session.selectedMatch else {
            CotabbyLogger.suggestion.debug(
                "emoji commit (key) skipped: no selectable match query=\"\(capture?.query ?? "")\""
            )
            teardownCapture()
            return
        }
        let glyph = selected.glyph
        let fallback = session.query.utf16.count + 1   // ":" + query
        recordUsage(for: selected)
        CotabbyLogger.suggestion.debug("emoji commit (key) glyph=\(glyph) query=\"\(session.query)\"")
        teardownCapture()
        scheduleReplaceEmojiQuery(with: glyph, fallbackUTF16: fallback)
    }

    /// The passed-through closing `:`. The field will hold `:query:` once the colon lands, so defer
    /// one runloop tick, then measure and replace the whole run.
    private func commitClosingColon() {
        guard let session = capture else {
            teardownCapture()
            return
        }
        let match = bestMatchForClosingColon(query: session.query)
        let fallback = session.query.utf16.count + 2   // ":" + query + ":"
        teardownCapture()
        guard let match else { return }   // no match: leave the literal ":query:" untouched
        recordUsage(for: match)
        scheduleReplaceEmojiQuery(with: match.glyph, fallbackUTF16: fallback)
    }

    /// Records a committed emoji against the user's usage history, keyed by its base primary alias so
    /// the signal is stable across skin-tone and gender variants.
    private func recordUsage(for match: EmojiMatch) {
        guard let alias = match.entry.aliases.first else { return }
        recordEmojiUsage(alias)
    }

    private func teardownCapture() {
        let wasCapturing = machine.isCapturing
        machine.reset()
        capture = nil
        pendingDecision = nil
        idleTimer.cancel()
        panel.hide()
        // Notify the coordinator so it drops the input monitor's interception when no capture remains.
        if wasCapturing {
            onCaptureStateChanged?()
        }
    }

    // MARK: - Matching and presentation

    private func rankedMatches(for query: String) -> [EmojiMatch] {
        let usage = emojiUsage()
        // A bare ":" (empty query) shows the user's recents, padded with popular emoji, instead of
        // nothing; a typed query runs the ranked search with the same personal usage signal.
        let base = query.isEmpty
            ? matcher.recents(usage: usage)
            : matcher.matches(for: query, usage: usage)
        return EmojiVariantResolver.resolve(base, preferences: emojiPreferences())
    }

    private func present(_ session: EmojiCaptureSession) {
        panel.show(
            query: session.query,
            matches: session.matches,
            selectedIndex: session.selectedIndex,
            caretRect: session.caretRect
        )
    }

    private func bestMatchForClosingColon(query: String) -> EmojiMatch? {
        let lowercased = query.lowercased()
        let results = EmojiVariantResolver.resolve(
            matcher.matches(for: query, usage: emojiUsage()),
            preferences: emojiPreferences()
        )
        if let exact = results.first(where: { $0.entry.aliases.contains(lowercased) }) {
            return exact
        }
        return results.first
    }

    /// Posts the delete+glyph replace on the next runloop tick. Both commit modes defer through here
    /// so the synthetic events are never posted re-entrantly from inside the keystroke's own tap
    /// callback: posting them synchronously from the observer pass makes the panel vanish with no
    /// emoji landing. Deferring also lets the field settle before the run to delete is measured.
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

    private func handleFocusSnapshot(_ snapshot: FocusSnapshot) {
        guard machine.isCapturing, var session = capture else { return }
        guard let context = InlineCaptureFocusGate.continuingContext(
            in: snapshot,
            focusChangeSequence: session.focusChangeSequence
        ) else {
            // The field changed (or went secure) under an open capture. This is the other common
            // "panel vanished mid-query" cause, so record it distinctly from a user cancel.
            CotabbyLogger.suggestion.debug("emoji capture cancelled: focus changed during capture")
            teardownCapture()
            return
        }
        // Follow the caret as the user types the query.
        session.caretRect = context.caretRect
        capture = session
        present(session)
    }

    private func armIdleTimer() {
        idleTimer.arm { [weak self] in self?.teardownCapture() }
    }
}
