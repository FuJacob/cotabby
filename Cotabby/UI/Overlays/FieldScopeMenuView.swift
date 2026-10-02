import AppKit
import SwiftUI

/// The popup shown when the user clicks Cotabby's field-edge icon: turn Autocomplete and Translate
/// on or off for the whole app, or for just this window (a chat, document, or page).
///
/// Presentation only. App-level answers are written to their existing owners (the disabled-apps
/// list in `SuggestionSettingsModel`, the app list in `TranslationPreferencesStore`), so Settings
/// and the popup always show the same thing; window answers go to `WindowFeatureOverrideStore`.
/// `onChange` tells `AppDelegate` which feature changed so it can refresh that coordinator right
/// away. Hosted by `FieldScopeMenuController` in a non-activating panel, which is why the controls
/// are plain switches and segmented pickers: they work on the first click without making Cotabby
/// the active app, so the host keeps keyboard focus.
struct FieldScopeMenuView: View {
    let target: FieldScopeTarget
    /// `@ObservedObject` (not `@StateObject`): these long-lived models belong to the app
    /// environment; the view only watches them so its switches update when they change.
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var translationPreferences: TranslationPreferencesStore
    @ObservedObject var windowOverrides: WindowFeatureOverrideStore
    let onChange: (ScopedFeature) -> Void
    let onOpenSettings: () -> Void

    /// A window's choice as a three-way picker: follow the app, or force on or off.
    private enum WindowChoice: Hashable {
        case sameAsApp, on, off

        init(_ override: Bool?) {
            switch override {
            case nil: self = .sameAsApp
            case true?: self = .on
            case false?: self = .off
            }
        }

        var override: Bool? {
            switch self {
            case .sameAsApp: return nil
            case .on: return true
            case .off: return false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.applicationName)
                    .font(.headline)
                if let title = target.windowTitle {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Divider()

            featureSection(
                title: "Autocomplete",
                feature: .autocomplete,
                appEnabled: Binding(
                    get: { !suggestionSettings.isApplicationDisabled(bundleIdentifier: target.bundleIdentifier) },
                    set: { enabled in
                        suggestionSettings.setApplicationDisabled(
                            bundleIdentifier: target.bundleIdentifier,
                            displayName: target.applicationName,
                            disabled: !enabled
                        )
                        onChange(.autocomplete)
                    }
                ),
                isAvailable: true
            )

            Divider()

            featureSection(
                title: "Translate",
                feature: .translation,
                appEnabled: Binding(
                    get: { translationPreferences.preferences.appBundleIdentifiers.contains(target.bundleIdentifier) },
                    set: { enabled in
                        translationPreferences.setApp(target.bundleIdentifier, included: enabled)
                        onChange(.translation)
                    }
                ),
                isAvailable: translationPreferences.preferences.isEnabled
            )
            if !translationPreferences.preferences.isEnabled {
                HStack {
                    Text("Translation is off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Turn On") {
                        translationPreferences.setEnabled(true)
                        onChange(.translation)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            Divider()

            Button("Settings…", action: onOpenSettings)
                .buttonStyle(.borderless)
                .font(.subheadline)
        }
        .padding(14)
        .frame(width: 272)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func featureSection(
        title: String,
        feature: ScopedFeature,
        appEnabled: Binding<Bool>,
        isAvailable: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(effectiveLabel(feature: feature, appEnabled: appEnabled.wrappedValue, isAvailable: isAvailable))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("In \(target.applicationName)", isOn: appEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)

            if let windowKey = target.windowKey {
                HStack {
                    Text("This window")
                    Spacer(minLength: 8)
                    Picker("This window", selection: Binding(
                        get: { WindowChoice(windowOverrides.override(for: feature, windowKey: windowKey)) },
                        set: { choice in
                            windowOverrides.setOverride(choice.override, for: feature, windowKey: windowKey)
                            onChange(feature)
                        }
                    )) {
                        Text("Same as app").tag(WindowChoice.sameAsApp)
                        Text("On").tag(WindowChoice.on)
                        Text("Off").tag(WindowChoice.off)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
            }
        }
        .disabled(!isAvailable)
    }

    /// "On here" / "Off here": the result of the app switch and the window choice together, so the
    /// user does not have to work out which of the two wins.
    private func effectiveLabel(feature: ScopedFeature, appEnabled: Bool, isAvailable: Bool) -> String {
        guard isAvailable else { return "Off" }
        let on = WindowFeatureScope.resolve(
            appEnabled: appEnabled,
            windowOverride: windowOverrides.override(for: feature, windowKey: target.windowKey)
        )
        return on ? "On here" : "Off here"
    }
}
