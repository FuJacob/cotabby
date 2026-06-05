import SwiftUI

/// File overview:
/// "Advanced" detail pane of the Settings window. It leads with a live preview sandbox — an editor
/// that completes as you type, showing the suggestion as gray ghost text inline (Tab to accept, Esc to
/// dismiss), exactly like Cotabby behaves in a real app — so the user can see how their settings and
/// Extended Context shape real output. Below it sits the Extended Context editor (a free-form blob
/// folded into every prompt) with its cost warning co-located, then a short "how this is used" note.
///
/// Why live preview leads (the redesign):
/// the previous layout buried a button-gated "Try it" box *below* the Extended Context editor, so
/// testing read as an afterthought and the click-to-run, static result didn't feel like the product.
/// Putting the live sandbox first makes testing the primary action and Extended Context the
/// configuration that feeds it. The pane stays named generically so future advanced toggles can land
/// here without a navigation rename.
///
/// The Extended Context editor binds through `SuggestionSettingsModel.setExtendedContext`, which
/// length-caps the value on write. Whitespace is intentionally NOT trimmed in the setter so the user
/// can type a trailing space; `SuggestionRequestFactory` does the once-per-request trim instead.
struct AdvancedPaneView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    let suggestionEngine: any SuggestionGenerating
    let configuration: SuggestionConfiguration

    @StateObject private var livePreview: LivePreviewModel

    private static let previewEditorMinHeight: CGFloat = 132
    private static let extendedContextEditorMinHeight: CGFloat = 220

    init(
        suggestionSettings: SuggestionSettingsModel,
        suggestionEngine: any SuggestionGenerating,
        configuration: SuggestionConfiguration
    ) {
        self.suggestionSettings = suggestionSettings
        self.suggestionEngine = suggestionEngine
        self.configuration = configuration
        _livePreview = StateObject(
            wrappedValue: LivePreviewModel(
                suggestionSettings: suggestionSettings,
                suggestionEngine: suggestionEngine,
                configuration: configuration
            )
        )
    }

    var body: some View {
        SettingsPaneScaffold {
            livePreviewSection
            extendedContextSection
            howThisIsUsedSection
        }
    }

    // MARK: - Live preview

    private var livePreviewSection: some View {
        Section("Live preview") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Type below and Cotabby completes as you go, using the same engine and settings " +
                    "it uses everywhere. Press Tab to accept the gray suggestion, Esc to dismiss.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                InlineCompletionEditor(
                    text: Binding(
                        get: { livePreview.userText },
                        set: { livePreview.userDidEdit($0) }
                    ),
                    ghost: livePreview.ghost,
                    onAccept: { livePreview.acceptGhost() },
                    onDismiss: { livePreview.dismissGhost() }
                )
                .frame(minHeight: Self.previewEditorMinHeight)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .accessibilityLabel("Live preview input")

                livePreviewStatusLine

                if let error = livePreview.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Nothing here is saved or shared; it only exercises the on-device model.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
        }
    }

    /// Left: a spinner while generating plus the active engine. Right: a Tab hint while a suggestion
    /// is showing, and the last generation's latency. Mirrors the cues the real overlay gives.
    private var livePreviewStatusLine: some View {
        HStack(spacing: 8) {
            if livePreview.isGenerating {
                ProgressView()
                    .controlSize(.small)
            }
            Text(livePreview.engineLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            if livePreview.hasGhost {
                Label("Tab to accept", systemImage: "arrow.right.to.line")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }

            if let latency = livePreview.lastLatencyMilliseconds {
                Text("\(latency) ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Extended Context

    private var extendedContextSection: some View {
        Section("Extended Context") {
            VStack(alignment: .leading, spacing: 12) {
                // The cost warning lives next to the editor it describes (it used to be a pane-level
                // banner) so the trade-off is read right where the user is about to paste a big block.
                SettingsCalloutView(
                    callout: SettingsPaneCallout(
                        tone: .warning,
                        message: "Everything here is sent to the model on every keystroke. Long blocks " +
                            "slow down completions and may crowd out the surrounding text the model " +
                            "needs to continue accurately."
                    )
                )

                Text("Paste a glossary, jargon list, style guide excerpt, or any reference the model " +
                    "should keep in mind. Markdown structure (headings, bullet lists, examples) is " +
                    "preserved verbatim.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: editorBinding)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: Self.extendedContextEditorMinHeight)
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

    /// Visual nudge when the user is within 10% of the cap so a long paste doesn't silently truncate
    /// without the user noticing the counter creeping toward the limit.
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
