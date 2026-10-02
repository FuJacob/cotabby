import SwiftUI

/// The Accept Word and Accept Entire Suggestion rows for one app: inherit the global key, record an
/// app-specific key, or disable the action there (for example, so Tab keeps its native job).
///
/// Extracted from the old flat Apps pane so the per-app detail screen can show it. It owns the one
/// active key recorder, which keeps two recorders from listening at once.
struct PerAppShortcutRowsView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    let bundleIdentifier: String
    let displayName: String

    @State private var recordingAction: PerAppShortcutAction?

    var body: some View {
        row(.acceptWord, title: "Accept Word", globalLabel: suggestionSettings.acceptanceKeyLabel)
        row(.acceptEntireSuggestion, title: "Accept Entire Suggestion", globalLabel: suggestionSettings.fullAcceptanceKeyLabel)
    }

    private var override: PerAppShortcutOverride? {
        suggestionSettings.perAppShortcutOverrides.first { $0.bundleIdentifier == bundleIdentifier }
    }

    @ViewBuilder
    private func row(_ action: PerAppShortcutAction, title: String, globalLabel: String) -> some View {
        let binding = resolvedBinding(action)
        let inherits = action == .acceptWord ? override?.acceptance == nil : override?.fullAcceptance == nil
        let isRecording = Binding(
            get: { recordingAction == action },
            set: { recordingAction = $0 ? action : (recordingAction == action ? nil : recordingAction) }
        )

        LabeledContent {
            if inherits {
                HStack(spacing: 8) {
                    if isRecording.wrappedValue {
                        KeyRecorderView(
                            onKeyRecorded: { keyCode, modifiers, label in
                                apply(action, keyCode: keyCode, modifiers: modifiers, label: label)
                                recordingAction = nil
                            },
                            onCancelled: { recordingAction = nil },
                            conflictChecker: conflictChecker(action)
                        )
                    } else {
                        Text("Uses global (\(binding.label))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Change") { recordingAction = action }
                        Button("Disable") { disable(action) }
                            .help("No key will \(title.lowercased()) in \(displayName).")
                    }
                }
            } else {
                KeybindRow(
                    label: binding.label,
                    keyCode: binding.keyCode,
                    isRecording: isRecording,
                    onRecord: { keyCode, modifiers, label in
                        apply(action, keyCode: keyCode, modifiers: modifiers, label: label)
                    },
                    onReset: { clear(action) },
                    resetLabel: "Use Global",
                    shouldShowReset: true,
                    onClear: { disable(action) },
                    clearLabel: "Disable",
                    clearHelp: "No key will \(title.lowercased()) in \(displayName).",
                    conflictChecker: conflictChecker(action)
                )
            }
        } label: {
            SettingsRowLabel(
                title: title,
                description: action == .acceptWord
                    ? "Disable it to keep \(globalLabel) doing its normal job in this app, such as indenting or moving between fields."
                    : "The key that inserts the whole suggestion in this app.",
                systemImage: action == .acceptWord ? "arrow.right.to.line" : "text.insert"
            )
        }
    }

    private func resolvedBinding(_ action: PerAppShortcutAction) -> ShortcutResolver.ResolvedBinding {
        switch action {
        case .acceptWord: return suggestionSettings.resolvedAcceptBinding(forBundleIdentifier: bundleIdentifier)
        case .acceptEntireSuggestion: return suggestionSettings.resolvedFullAcceptBinding(forBundleIdentifier: bundleIdentifier)
        }
    }

    private func apply(_ action: PerAppShortcutAction, keyCode: CGKeyCode, modifiers: ShortcutModifierMask, label: String) {
        switch action {
        case .acceptWord:
            suggestionSettings.setPerAppAcceptKey(
                bundleIdentifier: bundleIdentifier, displayName: displayName,
                keyCode: keyCode, modifiers: modifiers, label: label
            )
        case .acceptEntireSuggestion:
            suggestionSettings.setPerAppFullAcceptKey(
                bundleIdentifier: bundleIdentifier, displayName: displayName,
                keyCode: keyCode, modifiers: modifiers, label: label
            )
        }
    }

    private func clear(_ action: PerAppShortcutAction) {
        switch action {
        case .acceptWord: suggestionSettings.clearPerAppAcceptKey(bundleIdentifier: bundleIdentifier)
        case .acceptEntireSuggestion: suggestionSettings.clearPerAppFullAcceptKey(bundleIdentifier: bundleIdentifier)
        }
    }

    private func disable(_ action: PerAppShortcutAction) {
        apply(action, keyCode: SuggestionSettingsModel.disabledKeyCode, modifiers: [], label: SuggestionSettingsModel.disabledKeyLabel)
    }

    private func conflictChecker(_ action: PerAppShortcutAction) -> (CGKeyCode, ShortcutModifierMask) -> String? {
        { keyCode, modifiers in
            suggestionSettings.conflictingPerAppShortcutName(
                forBundleIdentifier: bundleIdentifier,
                keyCode: keyCode,
                modifiers: modifiers,
                excluding: action.shortcutAction
            )
        }
    }
}

enum PerAppShortcutAction: Equatable {
    case acceptWord
    case acceptEntireSuggestion

    var shortcutAction: ShortcutAction {
        switch self {
        case .acceptWord: return .acceptWord
        case .acceptEntireSuggestion: return .acceptEntireSuggestion
        }
    }
}
