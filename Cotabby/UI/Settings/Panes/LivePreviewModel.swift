import Combine
import CoreGraphics
import Foundation

/// File overview:
/// View model for the Advanced pane's live preview sandbox. Owns the user's typed text, the current
/// ghost suggestion, and the debounced generation that produces it. Unlike the old one-shot "Try it"
/// playground (a button that ran a single completion), this regenerates as the user pauses typing and
/// surfaces the result as inline ghost text, so the sandbox behaves like Cotabby does in a real app.
///
/// Pane-private on purpose: it shapes one section of one settings pane, so it lives next to that pane
/// rather than in a shared layer where it would invite reuse it doesn't need.
///
/// Generation reuses the production path end to end: `SuggestionRequestFactory.buildRequest` builds
/// the same request the live coordinator builds, and `SuggestionWorkController` provides the same
/// debounce + stale-result guarding. Only the trigger (typing pauses instead of focus events) and the
/// synthetic focus context are sandbox-specific.
@MainActor
final class LivePreviewModel: ObservableObject {
    /// The user's authoritative text. Bound to the editor; never contains the ghost.
    @Published var userText: String = ""
    /// The current completion suffix shown as gray ghost text, or "" when none.
    @Published private(set) var ghost: String = ""
    @Published private(set) var isGenerating = false
    @Published private(set) var lastLatencyMilliseconds: Int?
    @Published private(set) var lastError: String?

    private let suggestionSettings: SuggestionSettingsModel
    private let suggestionEngine: any SuggestionGenerating
    private let configuration: SuggestionConfiguration
    private let workController = SuggestionWorkController()
    private let debounceMilliseconds: Int

    /// Debounce window for the sandbox. Deliberately longer than the live pipeline's default so we
    /// don't fire a generation on every keystroke while the user is still typing in the box, while
    /// still feeling responsive once they pause. `nonisolated` so it can serve as the init's default
    /// argument (evaluated outside the main actor).
    nonisolated static let defaultDebounceMilliseconds = 300

    init(
        suggestionSettings: SuggestionSettingsModel,
        suggestionEngine: any SuggestionGenerating,
        configuration: SuggestionConfiguration,
        debounceMilliseconds: Int = LivePreviewModel.defaultDebounceMilliseconds
    ) {
        self.suggestionSettings = suggestionSettings
        self.suggestionEngine = suggestionEngine
        self.configuration = configuration
        self.debounceMilliseconds = debounceMilliseconds
    }

    /// Human-readable name of the engine that will service the next generation, for the status line.
    var engineLabel: String {
        suggestionSettings.snapshot.selectedEngine.displayLabel
    }

    var hasGhost: Bool { !ghost.isEmpty }

    /// Called by the editor whenever the user edits the text. Clears the now-stale ghost and schedules
    /// a fresh debounced generation.
    func userDidEdit(_ newText: String) {
        userText = newText
        clearGhost()
        scheduleGeneration()
    }

    /// Commit the ghost into the user's text (Tab), then keep the flow going by generating the next
    /// continuation from the grown text.
    func acceptGhost() {
        guard !ghost.isEmpty else { return }
        userText += ghost
        clearGhost()
        scheduleGeneration()
    }

    /// Drop the current ghost without committing it (Esc / caret moved away) and stop any pending work.
    func dismissGhost() {
        clearGhost()
        isGenerating = false
        workController.cancelAll()
    }

    private func clearGhost() {
        if !ghost.isEmpty { ghost = "" }
    }

    private func scheduleGeneration() {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isGenerating = false
            workController.cancelAll()
            return
        }
        isGenerating = true
        lastError = nil
        workController.replaceDebouncedWork(delayMilliseconds: debounceMilliseconds) { [weak self] workID in
            await self?.generate(workID: workID)
        }
    }

    private func generate(workID: UInt64) async {
        let prefixText = userText
        let build = SuggestionRequestFactory.buildRequest(
            context: Self.makeSyntheticContext(prefixText: prefixText),
            settings: suggestionSettings.snapshot,
            configuration: configuration
        )
        do {
            let result = try await suggestionEngine.generateSuggestion(for: build.request)
            // Belt-and-suspenders alongside task cancellation: ignore a result whose work was already
            // superseded by a newer keystroke (relevant if an engine ever ignores cancellation).
            guard workController.isCurrent(workID) else { return }
            ghost = result.text
            lastLatencyMilliseconds = Int((result.latency * 1000).rounded())
            lastError = nil
            isGenerating = false
        } catch is CancellationError {
            // Superseded by a newer keystroke; whoever owns the current work now owns the UI state.
            return
        } catch {
            guard workController.isCurrent(workID) else { return }
            lastError = error.localizedDescription
            ghost = ""
            lastLatencyMilliseconds = nil
            isGenerating = false
        }
    }

    /// Builds a `FocusedInputContext` from the user's test text with the caret at the end. The values
    /// are intentionally generic — the sandbox is a prompt-shape demo, not an attempt to mimic a
    /// specific host app's accessibility surface — and the bundle id does not match a real app so
    /// per-app tone hints fall through to defaults.
    private static func makeSyntheticContext(prefixText: String) -> FocusedInputContext {
        let snapshot = FocusedInputSnapshot(
            applicationName: "Cotabby Playground",
            bundleIdentifier: "com.cotabby.advanced.playground",
            processIdentifier: 0,
            elementIdentifier: "playground-field",
            role: "AXTextArea",
            subrole: nil,
            caretRect: CGRect(x: 0, y: 0, width: 2, height: 18),
            inputFrameRect: CGRect(x: 0, y: 0, width: 320, height: 96),
            caretSource: "playground",
            caretQuality: .exact,
            observedCharWidth: nil,
            precedingText: prefixText,
            trailingText: "",
            selection: NSRange(location: (prefixText as NSString).length, length: 0),
            isSecure: false,
            focusChangeSequence: 0
        )
        return FocusedInputContext(snapshot: snapshot, generation: 0)
    }
}
