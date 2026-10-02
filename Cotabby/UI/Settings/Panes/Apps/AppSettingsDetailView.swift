import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Everything Cotabby does differently in one app: completions on/off, mid-line completions,
/// autocorrect, accept keys, app instructions, and that app's typing history.
///
/// Presentation only. Each control writes to the store that owns the concept, so there is no
/// second copy of any setting: the disabled-apps list (completions), the per-app override record
/// (keys and `PerAppBehavior`), and `TypingHistoryStore` (collection, count, deletion).
struct AppSettingsDetailView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var typingHistory: TypingHistoryStore
    let bundleIdentifier: String
    let displayName: String
    let onBack: () -> Void

    @State private var isConfirmingDelete = false

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Button(action: onBack) {
                    Label("All Apps", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                Image(nsImage: AppIconCache.icon(for: bundleIdentifier))
                    .resizable()
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName).font(.title3.weight(.semibold))
                    Text(bundleIdentifier).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }

        Section("Completions") {
            Picker(selection: completionsBinding) {
                Text("Default (\(onOff(suggestionSettings.isGloballyEnabled)))").tag(PerAppToggle.useDefault)
                Text("Off").tag(PerAppToggle.off)
            } label: {
                SettingsRowLabel(
                    title: "Enable Completions",
                    description: "Turn suggestions off in this app, for example one with its own autocomplete.",
                    systemImage: "text.cursor"
                )
            }

            Picker(selection: behaviorBinding(\.midLineCompletions)) {
                Text("Default (on)").tag(PerAppToggle.useDefault)
                Text("On").tag(PerAppToggle.on)
                Text("Off").tag(PerAppToggle.off)
            } label: {
                SettingsRowLabel(
                    title: "Mid-Line Completions",
                    description: "Suggest even when there is text after the cursor on the same line. " +
                        "Turn off if suggestions get in the way of existing text here.",
                    systemImage: "text.insert"
                )
            }

            Picker(selection: behaviorBinding(\.autocorrect)) {
                Text("Default (\(onOff(PerAppSettingsResolver.globalAutocorrectIsOn(suggestionSettings.snapshot))))")
                    .tag(PerAppToggle.useDefault)
                Text("On").tag(PerAppToggle.on)
                Text("Off").tag(PerAppToggle.off)
            } label: {
                SettingsRowLabel(
                    title: "Autocorrect",
                    description: "Offer a correction when the word you're typing looks misspelled. " +
                        "Covers only the current word.",
                    systemImage: "textformat.abc.dottedunderline"
                )
            }
        }

        Section("Keys") {
            PerAppShortcutRowsView(
                suggestionSettings: suggestionSettings,
                bundleIdentifier: bundleIdentifier,
                displayName: displayName
            )
        }

        Section("Instructions for This App") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Notes the model keeps in mind only in \(displayName): its language, tone, or terms. " +
                    "They are added to your Extended Context, so they reach the selected engine the same way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: instructionsBinding)
                    .font(.system(size: 13))
                    .frame(minHeight: 90)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .accessibilityLabel("Instructions for \(displayName)")
                Text("\(behavior.instructions.count) / \(PerAppBehavior.maximumInstructionCharacters) characters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 4)
        }

        Section("Typing History") {
            Picker(selection: collectBinding) {
                Text("Default (\(onOff(typingHistory.preferences.isRecording)))").tag(PerAppToggle.useDefault)
                Text("Off").tag(PerAppToggle.off)
            } label: {
                SettingsRowLabel(
                    title: "Collect Inputs",
                    description: "Record what you type in this app so suggestions adapt to how you write. " +
                        "Encrypted and stored only on this Mac.",
                    systemImage: "clock.arrow.circlepath"
                )
            }

            LabeledContent {
                Button("Delete…", role: .destructive) { isConfirmingDelete = true }
                    .disabled(inputCount == 0)
            } label: {
                Text(inputCount == 1 ? "1 input collected in this app" : "\(inputCount) inputs collected in this app")
            }
            .confirmationDialog("Delete \(inputCount) inputs from \(displayName)?", isPresented: $isConfirmingDelete) {
                Button("Delete", role: .destructive) {
                    typingHistory.deleteRecords(forBundleIdentifier: bundleIdentifier)
                }
            } message: {
                Text("History from other apps is kept. This can't be undone.")
            }
        }

        Section {
            Button("Reset \(displayName) to Defaults") { resetToDefaults() }
                .help("Turn completions back on and remove this app's keys, behavior, and history exclusion.")
        }
    }

    // MARK: - Bindings

    private var behavior: PerAppBehavior {
        suggestionSettings.perAppBehavior(forBundleIdentifier: bundleIdentifier)
    }

    private var inputCount: Int {
        typingHistory.recordCountsByApp[bundleIdentifier] ?? 0
    }

    private var completionsBinding: Binding<PerAppToggle> {
        Binding(
            get: { suggestionSettings.isApplicationDisabled(bundleIdentifier: bundleIdentifier) ? .off : .useDefault },
            set: { choice in
                if choice == .off {
                    suggestionSettings.disableApplication(bundleIdentifier: bundleIdentifier, displayName: displayName)
                } else {
                    suggestionSettings.removeDisabledApplication(bundleIdentifier: bundleIdentifier)
                }
            }
        )
    }

    private func behaviorBinding(_ keyPath: WritableKeyPath<PerAppBehavior, PerAppToggle>) -> Binding<PerAppToggle> {
        Binding(
            get: { behavior[keyPath: keyPath] },
            set: { value in
                suggestionSettings.updatePerAppBehavior(bundleIdentifier: bundleIdentifier, displayName: displayName) {
                    $0[keyPath: keyPath] = value
                }
            }
        )
    }

    private var instructionsBinding: Binding<String> {
        Binding(
            get: { behavior.instructions },
            set: { text in
                suggestionSettings.updatePerAppBehavior(bundleIdentifier: bundleIdentifier, displayName: displayName) {
                    $0.instructions = text
                }
            }
        )
    }

    private var collectBinding: Binding<PerAppToggle> {
        Binding(
            get: { typingHistory.preferences.excludedBundleIdentifiers.contains(bundleIdentifier) ? .off : .useDefault },
            set: { typingHistory.setExcluded(bundleIdentifier, excluded: $0 == .off) }
        )
    }

    private func onOff(_ value: Bool) -> String { value ? "on" : "off" }

    private func resetToDefaults() {
        suggestionSettings.removeDisabledApplication(bundleIdentifier: bundleIdentifier)
        suggestionSettings.removePerAppOverride(bundleIdentifier: bundleIdentifier)
        typingHistory.setExcluded(bundleIdentifier, excluded: false)
    }
}

/// App icons and names looked up once per bundle identifier. `NSWorkspace` lookups hit Launch
/// Services; caching keeps a long app list from repeating them on every redraw.
@MainActor
enum AppIconCache {
    private static var icons: [String: NSImage] = [:]
    private static var names: [String: String] = [:]

    static func icon(for bundleIdentifier: String) -> NSImage {
        if let cached = icons[bundleIdentifier] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
        icons[bundleIdentifier] = icon
        return icon
    }

    static func displayName(for bundleIdentifier: String) -> String {
        if let cached = names[bundleIdentifier] { return cached }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? bundleIdentifier
        names[bundleIdentifier] = name
        return name
    }
}
