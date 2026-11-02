import Combine
import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Orchestrates "synonyms for the selected word": when the focused field's selection becomes one
/// word, ask the user's selected engine for synonyms, show them as a numbered single-row preview near
/// the caret, and replace the selection when the user presses 1–9.
///
/// It is the third inline feature beside `EmojiPickerController` (`:`) and `MacroController` (`/`)
/// and follows their keystroke contract: `observe` records a per-key consume decision during the
/// listen-only observer pass, and `decideCaptureKey` hands it back to the active tap for the same
/// key. `InlineCommandCoordinator` owns the input monitor's single decider and interception flag, so
/// the active tap is installed only while the list is visible; with no list, digits are never seen
/// by a consuming tap at all.
///
/// Unlike the sigil features it is driven by focus snapshots, not keystrokes: a selection is
/// something the user does with the mouse or Shift-arrows, and the focus tracker is what notices it.
/// Created once by `CotabbyAppEnvironment` and lives for the app's lifetime.
@MainActor
final class SynonymController {
    private let panel: any InlinePreviewPresenting
    private let focusModel: any SuggestionFocusProviding
    private let inserter: any EmojiTextInserting
    private let engine: any SuggestionGenerating
    /// The suggestion availability gate (setting, per-app and per-domain lists, terminals, pause,
    /// permissions) evaluated without the field-capability verdict, which a selection always fails.
    /// Production wires it to `SuggestionCoordinator.synonymDisabledReason(focusSnapshot:)`.
    private let disabledReason: @MainActor (FocusSnapshot) -> String?

    /// Invoked when the list appears or disappears, so the coordinator can install or remove the
    /// consuming tap. Dismissal often happens outside `observe` (selection change, click away).
    var onCaptureStateChanged: (() -> Void)?

    /// The selection the controller last reacted to. Kept after the list is dismissed (Esc, a pick,
    /// a click) so the same selection does not reopen it; only a different selection does.
    private var target: Target?
    private var choices: [String] = []
    private var generationTask: Task<Void, Never>?
    private var pendingDecision: PendingDecision?
    private var cancellables = Set<AnyCancellable>()

    /// One selected word in one field. `selection` tells a re-selection of the same word elsewhere
    /// in the field apart from the one already handled.
    private struct Target: Equatable {
        let word: String
        let selection: NSRange
        let focusChangeSequence: UInt64
    }

    private struct PendingDecision {
        let keyCode: CGKeyCode
        let consume: Bool
    }

    /// A short pause before asking the engine, so dragging a selection across a word (which publishes
    /// "w", "wo", "wor", ...) asks once for the final word rather than once per letter.
    static let settleNanoseconds: UInt64 = 250_000_000

    /// True while the numbered list is on screen; this is when digit keys belong to the feature.
    var isCapturing: Bool { !choices.isEmpty }

    init(
        panel: any InlinePreviewPresenting,
        focusModel: any SuggestionFocusProviding,
        inserter: any EmojiTextInserting,
        engine: any SuggestionGenerating,
        disabledReason: @escaping @MainActor (FocusSnapshot) -> String?
    ) {
        self.panel = panel
        self.focusModel = focusModel
        self.inserter = inserter
        self.engine = engine
        self.disabledReason = disabledReason
    }

    func start() {
        // The shared preview panel accepts on click for macros; a synonym needs a number, so a click
        // on the list (like one outside it) just dismisses.
        panel.onClick = { [weak self] in self?.dismiss() }
        panel.onClickOutside = { [weak self] in self?.dismiss() }
        focusModel.snapshotPublisher
            .sink { [weak self] snapshot in self?.handleFocusSnapshot(snapshot) }
            .store(in: &cancellables)
    }

    func stop() {
        target = nil
        dismiss()
        cancellables.removeAll()
    }

    // MARK: - Selection

    private func handleFocusSnapshot(_ snapshot: FocusSnapshot) {
        let next = eligibleTarget(in: snapshot)
        guard next != target else { return }
        // Any other selection (none, a phrase, another word, another field) ends the current list
        // and cancels a generation still in flight for the old word.
        dismiss()
        target = next
        guard let next, let field = snapshot.context else { return }

        // `Task { }` inherits the main actor from this method. The engine call suspends here while the
        // engines do their decoding away from the main actor (llama's serialized native core,
        // Foundation Models' session, or URLSession for an endpoint), so the UI never waits on it.
        generationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.settleNanoseconds)
            guard !Task.isCancelled, let engine = self?.engine else { return }
            let request = SelectedWordSynonyms.request(for: next.word, in: field)
            let result = try? await engine.generateSuggestion(for: request)
            // Stale-result guard: the selection may have changed while the engine worked. Cancellation
            // covers most of that, but an engine that ignores it still must not show an old list.
            guard !Task.isCancelled, let self, self.target == next, let result else { return }
            self.present(SelectedWordSynonyms.parse(result.text, original: next.word), at: field.caretRect)
        }
    }

    private func eligibleTarget(in snapshot: FocusSnapshot) -> Target? {
        guard let word = SelectedWordSynonyms.selectedWord(in: snapshot),
              let context = snapshot.context,
              disabledReason(snapshot) == nil else {
            return nil
        }
        return Target(word: word, selection: context.selection, focusChangeSequence: context.focusChangeSequence)
    }

    private func present(_ newChoices: [String], at caretRect: CGRect) {
        guard !newChoices.isEmpty else { return }
        choices = newChoices
        panel.show(previewText: SelectedWordSynonyms.listLabel(newChoices), caretRect: caretRect, acceptKeyLabel: nil)
        onCaptureStateChanged?()
    }

    /// Hides the list and cancels any generation. Keeps `target`, so the same selection stays quiet.
    private func dismiss() {
        generationTask?.cancel()
        generationTask = nil
        pendingDecision = nil
        guard isCapturing else { return }
        choices = []
        panel.hide()
        onCaptureStateChanged?()
    }

    // MARK: - Keystroke observation

    /// Returns true when the key belongs to the list (a pick or Esc), so the suggestion pipeline and
    /// the other inline features stand down for it.
    @discardableResult
    func observe(_ event: CapturedInputEvent) -> Bool {
        guard isCapturing else {
            pendingDecision = nil
            return false
        }

        let modifiers = ShortcutModifierMask(eventFlags: event.flags)
        if let index = SelectedWordSynonyms.choiceIndex(characters: event.characters, modifiers: modifiers),
           index < choices.count {
            commit(choices[index])
            pendingDecision = PendingDecision(keyCode: event.keyCode, consume: true)
            return true
        }

        // Esc is swallowed: it was aimed at the list, and the host might otherwise close a sheet.
        // Every other key dismisses and reaches the app untouched (typing replaces the selection as
        // usual, arrows move the caret, Cmd-C copies).
        let isEscape = event.keyCode == 53
        dismiss()
        pendingDecision = PendingDecision(keyCode: event.keyCode, consume: isEscape)
        return isEscape
    }

    func decideCaptureKey(_ keyEvent: InputMonitorKeyEvent) -> InputMonitorAcceptTapDecision {
        guard let pending = pendingDecision, pending.keyCode == keyEvent.keyCode else {
            return .notHandled
        }
        pendingDecision = nil
        return pending.consume ? .consume : .passThrough
    }

    /// Types `synonym` over the selection: a synthetic keystroke into a field with selected text
    /// replaces that text, so nothing is deleted first. Posted on the next run-loop tick so the
    /// synthetic event is never re-entrant from inside the digit's own tap callback, and only while
    /// the same word is still selected in the same field; otherwise it would type into whatever the
    /// user moved to.
    private func commit(_ synonym: String) {
        let expected = target
        dismiss()
        DispatchQueue.main.async { [weak self] in
            guard let self, let expected else { return }
            let snapshot = self.focusModel.snapshot
            guard SelectedWordSynonyms.selectedWord(in: snapshot) == expected.word,
                  snapshot.context?.focusChangeSequence == expected.focusChangeSequence else {
                CotabbyLogger.suggestion.debug("synonym commit skipped: selection moved before the replace")
                return
            }
            _ = self.inserter.replace(deletingCharacterCount: 0, with: synonym)
            self.focusModel.refreshNow()
        }
    }
}
