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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(target.applicationName)
                        .font(.system(size: 12, weight: .semibold))
                    if let title = target.windowTitle {
                        Text(title)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Open Cotabby Settings")
            }

            Divider()

            featureRow(
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

            featureRow(
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
                HStack(spacing: 4) {
                    Text("Translation is off.")
                        .foregroundStyle(.secondary)
                    Button("Turn On") {
                        translationPreferences.setEnabled(true)
                        onChange(.translation)
                    }
                    .buttonStyle(.link)
                }
                .font(.system(size: 10))
            }
        }
        .padding(10)
        .frame(width: 216)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
        }
    }

    /// One feature: its name, the app switch, and (when the window can be told apart) a compact
    /// window picker. The switch is the app's setting; the picker overrides it for this window.
    @ViewBuilder
    private func featureRow(
        title: String,
        feature: ScopedFeature,
        appEnabled: Binding<Bool>,
        isAvailable: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                Spacer(minLength: 6)
                Toggle(title, isOn: appEnabled)
                    .toggleStyle(CompactSwitchStyle())
                    .labelsHidden()
                    .help("\(title) in all of \(target.applicationName)")
            }

            if let windowKey = target.windowKey {
                HStack(spacing: 6) {
                    Text("This window")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Picker("This window", selection: Binding(
                        get: { WindowChoice(windowOverrides.override(for: feature, windowKey: windowKey)) },
                        set: { choice in
                            windowOverrides.setOverride(choice.override, for: feature, windowKey: windowKey)
                            onChange(feature)
                        }
                    )) {
                        Text("App").tag(WindowChoice.sameAsApp)
                        Text("On").tag(WindowChoice.on)
                        Text("Off").tag(WindowChoice.off)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.mini)
                    .fixedSize()
                    .help("App follows the switch above; On or Off applies to this window only.")
                }
            }
        }
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.5)
    }
}

/// A small switch drawn in SwiftUI.
///
/// Why not the system switch: this popup lives in a non-activating panel that is never the key
/// window (so the host keeps focus), and AppKit draws its controls in an inactive window gray,
/// which made "on" look "off". This style draws the accent color from the value alone.
private struct CompactSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Capsule()
            .fill(configuration.isOn ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
            .frame(width: 26, height: 15)
            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .padding(1.5)
                    .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
            }
            .animation(.easeOut(duration: 0.12), value: configuration.isOn)
            .contentShape(Capsule())
            .onTapGesture {
                guard isEnabled else { return }
                configuration.isOn.toggle()
            }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}
