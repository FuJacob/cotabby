import SwiftUI

/// File overview:
/// "Context" detail pane of the Settings window. It leads with a live preview: a real, native text
/// field that the running app completes in exactly as it does anywhere else. Typing in it drives the
/// production focus -> suggestion -> overlay pipeline end to end, so the gray suggestion, Tab to
/// accept, and Esc to dismiss are the real thing, not an in-app reimplementation. Below it sit the
/// Extended Context editor (a free-form blob folded into every prompt) with its cost warning
/// co-located, a short "how this is used" note, and the Typing History section.
///
/// Why the field is real: `FocusTracker` lifts its "never complete in our own UI" rule for this one
/// element (keyed on `ContextLivePreview.accessibilityIdentifier`) and the real overlay draws the
/// suggestion at the caret, so the text view owns its string outright and nothing competes with the
/// user's typing. See `ContextLivePreviewField` for why an in-app ghost renderer cannot do that.
///
/// Why a dedicated pane (not Writing): the Writing pane carries name and language personalization.
/// Extended Context is a different shape (long-form, free markdown, and noticeably more expensive on
/// the token budget), so it keeps its own pane with room for the cost-of-use warning.
///
/// The Extended Context editor binds through `SuggestionSettingsModel.setExtendedContext`, which
/// length-caps the value on write. Whitespace is intentionally NOT trimmed in the setter so the user
/// can type a trailing space; `SuggestionRequestFactory` does the once-per-request trim instead.
struct ContextPaneView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    /// Owned by `CotabbyAppEnvironment`; drives the Typing History section.
    @ObservedObject var typingHistory: TypingHistoryStore

    private static let previewEditorMinHeight: CGFloat = 132
    private static let extendedContextEditorMinHeight: CGFloat = 220

    var body: some View {
        SettingsPaneScaffold {
            livePreviewSection
            extendedContextSection
            howThisIsUsedSection
            TypingHistorySectionView(store: typingHistory)
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

                ContextLivePreviewField()
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

                // The active engine, so the user knows which backend they're exercising. The live
                // suggestion, latency, and accept cues come from the real overlay, not this pane.
                Text(suggestionSettings.selectedEngine.displayLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(Self.livePreviewPrivacyNote(for: suggestionSettings.selectedEngine))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .settingsItem(.contextLivePreview)
        }
    }

    /// The preview drives the real pipeline, so its privacy note must follow the selected engine.
    /// Apple Intelligence and Open Source keep the typed text on this Mac; a configured endpoint,
    /// which may be on the LAN or the internet, receives it exactly as it would from any field.
    /// Cotabby can only speak for itself: what the endpoint retains is that server's policy.
    static func livePreviewPrivacyNote(for engine: SuggestionEngineKind) -> String {
        switch engine {
        case .appleIntelligence, .llamaOpenSource:
            return "Nothing here is saved or shared; it only exercises the on-device model."
        case .openAICompatible:
            return "Cotabby doesn't save this text, but like any other field it's sent to your configured endpoint, "
                + "which may keep it."
        }
    }

    // MARK: - Extended Context

    private var extendedContextSection: some View {
        Section("Extended Context") {
            VStack(alignment: .leading, spacing: 12) {
                // The cost warning sits next to the editor it describes so the trade-off is read
                // right where the user is about to paste a big block.
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

                TextEditor(text: suggestionSettings.binding(\.extendedContext) { $0.setExtendedContext($1) })
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
            .settingsItem(.extendedContext)
        }
    }

    private var howThisIsUsedSection: some View {
        Section("How this is used") {
            VStack(alignment: .leading, spacing: 8) {
                bulletLine(
                    "Sent on every suggestion as reference material, not as instructions."
                )
                bulletLine(
                    "Subordinate to Cotabby's base autocomplete rules, so it cannot override " +
                        "core behavior."
                )
                bulletLine(
                    "Capped at \(SuggestionSettingsStore.maximumExtendedContextCharacters) " +
                        "characters. Anything pasted beyond that is trimmed automatically."
                )
                bulletLine(
                    "Stored locally on this Mac. Included in requests to your selected " +
                        "engine, including a configured endpoint."
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Helpers

    private var characterCountLabel: String {
        let current = suggestionSettings.extendedContext.count
        let maximum = SuggestionSettingsStore.maximumExtendedContextCharacters
        return "\(current) / \(maximum) characters"
    }

    /// Visual nudge when the user is within 10% of the cap so a long paste doesn't silently truncate
    /// without the user noticing the counter creeping toward the limit.
    private var isApproachingLimit: Bool {
        let current = suggestionSettings.extendedContext.count
        let maximum = SuggestionSettingsStore.maximumExtendedContextCharacters
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
