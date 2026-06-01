import Combine
import SwiftUI

/// File overview:
/// "Advanced" detail pane of the Settings window. Holds the Extended Context editor (a free-form
/// text blob folded into every prompt) and a small "Try it" playground for verifying that the
/// editor's content is actually shaping the model's output. The pane is named generically so
/// future advanced toggles (model tuning, debug flags, prompt knobs) can land here without a
/// second navigation rename.
///
/// Why a dedicated pane (not Writing):
/// The Writing pane already carries the tag-style `customRules` editor (short imperative
/// directives) plus name and language. Extended Context is a different shape: long-form, free
/// markdown, and noticeably more expensive on the token budget. Keeping it in its own pane (a)
/// leaves Writing focused on small, additive personalization, and (b) makes room for the
/// cost-of-use warnings without crowding the existing settings.
///
/// The text editor binds through `SuggestionSettingsModel.setExtendedContext`, which length-caps
/// the value on write. Whitespace is intentionally NOT trimmed in the setter so the user can type
/// a space at the end of a word — `SuggestionRequestFactory` does the once-per-request trim
/// instead.
struct AdvancedPaneView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    let suggestionEngine: any SuggestionGenerating
    let configuration: SuggestionConfiguration

    @StateObject private var playground: ExtendedContextPlaygroundModel

    private static let editorMinHeight: CGFloat = 280

    init(
        suggestionSettings: SuggestionSettingsModel,
        suggestionEngine: any SuggestionGenerating,
        configuration: SuggestionConfiguration
    ) {
        self.suggestionSettings = suggestionSettings
        self.suggestionEngine = suggestionEngine
        self.configuration = configuration
        _playground = StateObject(
            wrappedValue: ExtendedContextPlaygroundModel(
                suggestionSettings: suggestionSettings,
                suggestionEngine: suggestionEngine,
                configuration: configuration
            )
        )
    }

    var body: some View {
        SettingsPaneScaffold(
            callout: SettingsPaneCallout(
                tone: .warning,
                message: "Everything in Extended Context is sent to the model on every keystroke. " +
                    "Long blocks slow down completions and may crowd out the surrounding text the " +
                    "model needs to continue accurately."
            )
        ) {
            extendedContextSection
            tryItSection
            howThisIsUsedSection
        }
    }

    // MARK: - Sections

    private var extendedContextSection: some View {
        Section("Extended Context") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste a glossary, jargon list, style guide excerpt, or any reference " +
                    "the model should keep in mind. Markdown structure (headings, bullet " +
                    "lists, examples) is preserved verbatim.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: editorBinding)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: Self.editorMinHeight)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .accessibilityLabel("Extended context notes")

                HStack {
                    Text(characterCountLabel)
                        .font(.caption)
                        .foregroundStyle(isApproachingLimit ? .orange : .secondary)
                        .monospacedDigit()

                    Spacer(minLength: 0)

                    Button("Clear", role: .destructive) {
                        suggestionSettings.setExtendedContext("")
                    }
                    .disabled(suggestionSettings.extendedContext.isEmpty)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var tryItSection: some View {
        Section("Try it") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Type a partial sentence below and run a completion to verify your " +
                    "Extended Context is shaping the output. Uses the currently selected " +
                    "engine and your live settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: $playground.testInput)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 84)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .accessibilityLabel("Test input for completion playground")

                HStack(spacing: 12) {
                    Button {
                        playground.runCompletion()
                    } label: {
                        if playground.isGenerating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Run completion")
                        }
                    }
                    .disabled(playground.isGenerating || playground.testInput.isEmpty)
                    .keyboardShortcut(.return, modifiers: [.command])

                    if playground.canShowResult {
                        Button("Clear result") {
                            playground.clearResult()
                        }
                    }

                    Spacer(minLength: 0)

                    if let latency = playground.lastLatencyMilliseconds {
                        Text("\(latency) ms")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                resultView
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var resultView: some View {
        if let error = playground.lastError {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.orange.opacity(0.08))
            )
        } else if let result = playground.lastResult {
            VStack(alignment: .leading, spacing: 6) {
                Text("Completion")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(result.isEmpty ? "(model returned empty text)" : result)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
            )
        }
    }

    private var howThisIsUsedSection: some View {
        Section("How this is used") {
            VStack(alignment: .leading, spacing: 8) {
                bulletLine(
                    "Sent on every suggestion as reference material — not as instructions."
                )
                bulletLine(
                    "Subordinate to Cotabby's base autocomplete rules, so it cannot override " +
                        "core behavior."
                )
                bulletLine(
                    "Capped at \(SuggestionSettingsModel.maximumExtendedContextCharacters) " +
                        "characters. Anything pasted beyond that is trimmed automatically."
                )
                bulletLine(
                    "Stored locally on this Mac. Nothing is uploaded; this only feeds the " +
                        "on-device model."
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Bindings & helpers

    private var editorBinding: Binding<String> {
        Binding(
            get: { suggestionSettings.extendedContext },
            set: { suggestionSettings.setExtendedContext($0) }
        )
    }

    private var characterCountLabel: String {
        let current = suggestionSettings.extendedContext.count
        let maximum = SuggestionSettingsModel.maximumExtendedContextCharacters
        return "\(current) / \(maximum) characters"
    }

    /// Visual nudge when the user is within 10% of the cap so a long paste doesn't silently
    /// truncate without the user noticing the counter creeping toward the limit.
    private var isApproachingLimit: Bool {
        let current = suggestionSettings.extendedContext.count
        let maximum = SuggestionSettingsModel.maximumExtendedContextCharacters
        return current >= Int(Double(maximum) * 0.9)
    }

    @ViewBuilder
    private func bulletLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// View model for the Advanced pane's "Try it" playground. Owns the test input text, the most
/// recent completion (or error), and the actor-isolated generation task.
///
/// Lives in this file because it is private to the Advanced pane and exists only to shape one
/// section of UI; lifting it out would invite reuse the playground doesn't need.
@MainActor
final class ExtendedContextPlaygroundModel: ObservableObject {
    @Published var testInput: String = ""
    @Published private(set) var lastResult: String?
    @Published private(set) var lastError: String?
    @Published private(set) var lastLatencyMilliseconds: Int?
    @Published private(set) var isGenerating: Bool = false

    private let suggestionSettings: SuggestionSettingsModel
    private let suggestionEngine: any SuggestionGenerating
    private let configuration: SuggestionConfiguration
    private var generationTask: Task<Void, Never>?
    /// Identifies the in-flight generation. Each `runCompletion` stamps a fresh UUID; only the
    /// task whose stamped ID still matches `currentGenerationID` is allowed to update UI state.
    /// This keeps a stale task (one that was superseded by a newer Run click, or cancelled by a
    /// future cancel button) from racing the active task to clear the spinner or overwrite
    /// `lastResult`. Equivalent to a per-request generation counter; UUID keeps the comparison
    /// trivially cheap on the main actor.
    private var currentGenerationID: UUID?

    init(
        suggestionSettings: SuggestionSettingsModel,
        suggestionEngine: any SuggestionGenerating,
        configuration: SuggestionConfiguration
    ) {
        self.suggestionSettings = suggestionSettings
        self.suggestionEngine = suggestionEngine
        self.configuration = configuration
    }

    var canShowResult: Bool {
        lastResult != nil || lastError != nil
    }

    func clearResult() {
        lastResult = nil
        lastError = nil
        lastLatencyMilliseconds = nil
    }

    /// Synthesizes a focused-input context from the user's test text and fires a single
    /// generation through the live router. The synthetic context's bundle id intentionally does
    /// not match a real app so per-app tone hints fall through to defaults; the goal here is to
    /// show how the user's prompt inputs (Extended Context, rules, language hint) shape the
    /// output, not to mimic a specific target app.
    func runCompletion() {
        guard !isGenerating else { return }
        let trimmed = testInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        clearResult()
        isGenerating = true

        let settingsSnapshot = suggestionSettings.snapshot
        let configuration = self.configuration
        let engine = self.suggestionEngine
        let prefixText = testInput
        let generationID = UUID()
        currentGenerationID = generationID

        generationTask?.cancel()
        generationTask = Task { @MainActor [weak self] in
            let context = Self.makeSyntheticContext(prefixText: prefixText)
            let result = SuggestionRequestFactory.buildRequest(
                context: context,
                settings: settingsSnapshot,
                configuration: configuration
            )
            let startedAt = Date()
            do {
                let suggestion = try await engine.generateSuggestion(for: result.request)
                guard let self, self.currentGenerationID == generationID else { return }
                self.lastResult = suggestion.text
                self.lastError = nil
                self.lastLatencyMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                self.currentGenerationID = nil
                self.isGenerating = false
            } catch is CancellationError {
                // Stale task — a newer `runCompletion` (or a future cancel handler) has already
                // stamped a fresh `currentGenerationID` or cleared it, so leave the spinner state
                // for whoever owns the current generation. Touching `isGenerating` here would
                // race with the active task.
                return
            } catch {
                guard let self, self.currentGenerationID == generationID else { return }
                self.lastError = error.localizedDescription
                self.lastResult = nil
                self.lastLatencyMilliseconds = nil
                self.currentGenerationID = nil
                self.isGenerating = false
            }
        }
    }

    /// Builds a `FocusedInputContext` from the user's test text. The values are intentionally
    /// generic — the playground is a prompt-shape demo, not an attempt to mimic a specific host
    /// app's accessibility surface.
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
