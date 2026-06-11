import SwiftUI

/// File overview:
/// Composes Cotabby's primary menu-bar control panel as a status-first surface
/// with inline quick controls for session-level preferences.
///
/// Design philosophy: the menu bar is the primary interaction surface for a menu bar app.
/// It shows status at a glance and exposes the controls users reach for mid-session
/// (engine, model, completion length). Rarely-changed settings (model management,
/// profile personalization, updates) live in the Settings window.
///
/// The focused-app context card was intentionally removed: opening the menu bar panel
/// steals focus from whatever app the user was typing in, so live focus state is always
/// stale by the time the panel renders.
struct MenuBarView: View {
    @ObservedObject var permissionManager: PermissionManager
    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    @ObservedObject var modelDownloadManager: ModelDownloadManager
    @ObservedObject var focusModel: FocusTrackingModel
    let permissionGuidanceController: PermissionGuidanceController
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var foundationModelAvailabilityService: FoundationModelAvailabilityService
    @ObservedObject var powerSourceMonitor: PowerSourceMonitor
    let appUpdateManager: AppUpdateManager
    let onOpenSettings: () -> Void
    let onReportFeedback: () -> Void

    /// Captures the popover's host window so `Button` actions that open another window can dismiss
    /// the popover behind them. SwiftUI's `\.dismiss` does not work for `MenuBarExtra(.window)`.
    @StateObject private var popoverDismisser = MenuBarPopoverDismisser()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider().padding(.bottom, 12)
            controlsSection
            permissionsCard
            footerSection
        }
        .padding(16)
        .frame(width: 340)
        .modifier(MenuBarWindowBackgroundModifier())
        .background(
            MenuBarPresentationObserver {
                permissionManager.refresh()
                runtimeModel.refreshAvailableModels()
            }
        )
        .background(MenuBarPopoverDismisserBinder(dismisser: popoverDismisser))
        .onAppear {
            permissionManager.refresh()
            runtimeModel.refreshAvailableModels()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        HStack(alignment: .center) {
            Text("Cotabby")
                .font(.headline)

            if let appShortVersion {
                Text(appShortVersion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Version \(appShortVersion)")
            }

            // Ko-fi tip jar lives next to the title because the menu bar surface is the most
            // frequented entry point. Using a Link lets SwiftUI hand the URL to NSWorkspace and
            // dismiss the popover; a Button would need its own handler plumbing for the same effect.
            if let kofiURL = URL(string: "https://ko-fi.com/cotabby") {
                Link("Support Us", destination: kofiURL)
                    .buttonStyle(.borderless)
                    .font(.subheadline)
            }

            Spacer(minLength: 0)

            Button("Report Bug", action: onReportFeedback)
                .buttonStyle(.borderless)
                .font(.subheadline)
        }
        .padding(.bottom, 12)
    }

    /// Short, user-facing app version (e.g. "0.4.2-beta") shown next to the title. Reads the bundle's
    /// `CFBundleShortVersionString`, the same canonical source the About pane uses.
    private var appShortVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    // MARK: - Quick controls

    /// Session-level preferences that users reach for mid-work: engine choice,
    /// model selection (when using local llama), and completion length.
    @ViewBuilder
    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Fast Mode", isOn: fastModeForcedOn ? .constant(true) : fastModeEnabledBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(fastModeForcedOn)

                if fastModeForcedOn {
                    Text("Forced on because Screen Recording is off")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Activation lives in its own band: the global switch plus the per-app override for
            // whatever app currently has focus.
            Group {
                Toggle("Enable Globally", isOn: globallyEnabledBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                if let application = focusModel.latestExternalApplication,
                   !TerminalAppDetector.isTerminal(bundleIdentifier: application.bundleIdentifier) {
                    Toggle("Enable in \(application.applicationName)", isOn: appEnabledBinding(for: application))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

            Divider()

            // Context-shaping toggles that change what the model is fed.
            Toggle("Include Clipboard Context", isOn: clipboardContextEnabledBinding)
                .toggleStyle(.switch)
                .controlSize(.small)

            Divider()

            // Generation setup: which engine/model produces completions and how long they run.
            // Wrapped in a Group so the four rows plus the toggles and dividers above stay under
            // SwiftUI's 10-child ViewBuilder limit for the enclosing VStack.
            Group {
                MenuBarPickerRow(title: "Engine") {
                    Picker("Engine", selection: selectedEngineBinding) {
                        ForEach(SuggestionEngineKind.allCases) { engine in
                            Text(engine.displayLabel)
                                .tag(engine)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                if suggestionSettings.selectedEngine == .appleIntelligence,
                   !foundationModelAvailabilityService.isAvailable {
                    Text(foundationModelAvailabilityService.userVisibleMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if suggestionSettings.selectedEngine.supportsLocalModelManagement {
                    modelRow
                }

                MenuBarPickerRow(title: "Length") {
                    Picker("Length", selection: lengthChoiceBinding) {
                        ForEach(SuggestionWordCountPreset.allCases) { preset in
                            Text(preset.displayLabel)
                                .tag(LengthChoice.preset(preset))
                        }
                        // The custom range stays editable from the Writing settings pane; selecting
                        // it here just flips the active mode and surfaces the current numbers so the
                        // user can tell at a glance which budget is in force.
                        Text("Custom (\(customRangeCompactLabel))")
                            .tag(LengthChoice.custom)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

            }
        }
        .padding(.bottom, 12)
    }

    /// Model selector with folder + refresh shortcuts — only visible when local llama engine is active.
    /// The picker is constrained to fill remaining row width so long filenames truncate inside the
    /// NSPopUpButton label instead of pushing the trailing icons off-row. Per-item `.lineLimit` /
    /// `.truncationMode` modifiers are unreliable here because AppKit's native popup ignores them
    /// for the selected-value label.
    @ViewBuilder
    private var modelRow: some View {
        MenuBarPickerRow(title: "Model") {
            HStack(spacing: 6) {
                if runtimeModel.availableModels.isEmpty {
                    Text("No models found")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    Picker("Model", selection: selectedModelBinding) {
                        ForEach(runtimeModel.availableModels) { model in
                            Text(model.displayName)
                                .tag(model.filename)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
                    .disabled(runtimePickerDisabled)
                }

                Button {
                    modelDownloadManager.openModelsDirectory()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

                Button {
                    modelDownloadManager.refreshModelStates()
                    runtimeModel.refreshAvailableModels()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Permissions (conditional)

    /// Lists every permission Cotabby can use and appears whenever at least one is missing, including
    /// the optional Screen Recording enhancement. Each row carries its own grant state, so the card
    /// keeps showing the still-missing permission until nothing is left to grant, then vanishes.
    /// Screen Recording is surfaced as a normal "(Optional)" permission row rather than hidden or
    /// shown as a feature toggle, but it never blocks autocomplete (see
    /// `CotabbyPermissionKind.isRequiredForAutocomplete`).
    @ViewBuilder
    private var permissionsCard: some View {
        if !allPermissionsGranted {
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions")
                    .font(.subheadline.weight(.medium))
                    .padding(.bottom, 2)

                ForEach(CotabbyPermissionKind.allCases) { permission in
                    PermissionRow(
                        title: permission.compactRowTitle,
                        granted: permissionManager.isGranted(permission),
                        action: { sourceFrameInScreen in
                            permissionGuidanceController.requestAccess(
                                for: permission,
                                sourceFrameInScreen: sourceFrameInScreen
                            )
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 12)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footerSection: some View {
        Divider()
            .padding(.bottom, 10)

        HStack {
            Button("Settings") {
                // Dismiss the popover before opening the Settings window so the popover doesn't
                // remain on top of (and obscure) the Settings pane. See issue #455.
                popoverDismisser.dismiss()
                onOpenSettings()
            }
            .buttonStyle(.borderless)

            Button("Check for Updates") {
                appUpdateManager.checkForUpdates()
            }
            .buttonStyle(.borderless)

            Spacer(minLength: 0)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q")
        }
        .font(.subheadline)
    }

    // MARK: - Bindings

    private var globallyEnabledBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isGloballyEnabled },
            set: { suggestionSettings.setGloballyEnabled($0) }
        )
    }

    private var clipboardContextEnabledBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isClipboardContextEnabled },
            set: { suggestionSettings.setClipboardContextEnabled($0) }
        )
    }

    private var fastModeEnabledBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isFastModeEnabled },
            set: { suggestionSettings.setFastModeEnabled($0) }
        )
    }

    private func appEnabledBinding(for application: FocusedApplicationIdentity) -> Binding<Bool> {
        Binding(
            get: {
                !suggestionSettings.isApplicationDisabled(
                    bundleIdentifier: application.bundleIdentifier
                )
            },
            set: { enabled in
                suggestionSettings.setApplicationDisabled(
                    bundleIdentifier: application.bundleIdentifier,
                    displayName: application.applicationName,
                    disabled: !enabled
                )
            }
        )
    }

    private var selectedEngineBinding: Binding<SuggestionEngineKind> {
        Binding(
            get: { suggestionSettings.selectedEngine },
            set: { engine in
                // With power-based switching on, the active engine is owned by the current power
                // source's profile. Editing it here writes that profile (battery vs. plugged-in)
                // instead of `selectedEngine`, which the switcher would otherwise revert. The profile
                // carries engine + model, so an Apple Intelligence pick drops the model and an Open
                // Source pick keeps the currently selected one.
                guard suggestionSettings.isPowerBasedModelSwitchingEnabled else {
                    suggestionSettings.selectEngine(engine)
                    return
                }
                let profile: PowerProfile = engine == .appleIntelligence
                    ? .appleIntelligence
                    : .llama(filename: runtimeModel.selectedModelFilename ?? "")
                applyProfileForCurrentPowerSource(profile)
            }
        )
    }

    private var selectedWordCountPresetBinding: Binding<SuggestionWordCountPreset> {
        Binding(
            get: { suggestionSettings.selectedWordCountPreset },
            set: { preset in
                suggestionSettings.selectWordCountPreset(preset)
            }
        )
    }

    /// One of the curated presets or the user's custom range. Backed by two pieces of state
    /// (`selectedWordCountPreset` + `isUsingCustomWordCountRange`) so the menu can render and
    /// mutate both with a single picker.
    private enum LengthChoice: Hashable {
        case preset(SuggestionWordCountPreset)
        case custom
    }

    private var lengthChoiceBinding: Binding<LengthChoice> {
        Binding(
            get: {
                suggestionSettings.isUsingCustomWordCountRange
                    ? .custom
                    : .preset(suggestionSettings.selectedWordCountPreset)
            },
            set: { choice in
                switch choice {
                case let .preset(preset):
                    suggestionSettings.setUsingCustomWordCountRange(false)
                    suggestionSettings.selectWordCountPreset(preset)
                case .custom:
                    suggestionSettings.setUsingCustomWordCountRange(true)
                }
            }
        )
    }

    private var customRangeCompactLabel: String {
        SuggestionWordRange.clamped(
            low: suggestionSettings.customWordCountLowWords,
            high: suggestionSettings.customWordCountHighWords
        ).compactLabel
    }

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: {
                runtimeModel.selectedModelFilename
                    ?? runtimeModel.availableModels.first?.filename
                    ?? ""
            },
            set: { filename in
                // With power-based switching on, write the model into the current power source's
                // profile so it sticks for that source (and the other source keeps its own model).
                // Calling `selectModel` directly would be reverted by the power switcher on its next
                // evaluation, which read as "the popup just resets my choice".
                guard suggestionSettings.isPowerBasedModelSwitchingEnabled else {
                    Task {
                        await runtimeModel.selectModel(filename)
                    }
                    return
                }
                applyProfileForCurrentPowerSource(.llama(filename: filename))
            }
        )
    }

    /// Writes a profile into whichever per-power-source slot is currently active, so a menu-bar edit
    /// updates the battery profile while on battery and the plugged-in profile while charging. The
    /// power-source observer then applies it to the runtime, so no direct `selectModel`/`selectEngine`
    /// call is needed here.
    private func applyProfileForCurrentPowerSource(_ profile: PowerProfile) {
        if powerSourceMonitor.isPluggedIn {
            suggestionSettings.setPluggedInProfile(profile)
        } else {
            suggestionSettings.setBatteryProfile(profile)
        }
    }

    private var runtimePickerDisabled: Bool {
        switch runtimeModel.state {
        case .starting, .loading:
            return true
        case .idle, .ready, .failed:
            return false
        }
    }

    // MARK: - Derived state

    private var allPermissionsGranted: Bool {
        permissionManager.allPermissionsGranted
    }

    /// Fast Mode is forced on and locked while Screen Recording is unavailable, since visual context
    /// can't run without it. The user's stored preference is preserved and restored once the
    /// permission is granted.
    private var fastModeForcedOn: Bool {
        !permissionManager.screenRecordingGranted
    }

}

/// Applies the menu panel's fill at the native window-container level when the OS supports it.
///
/// `MenuBarView` owns the menu contents, but SwiftUI owns the actual `NSWindow` created by
/// `MenuBarExtra`. Keeping this as a dedicated modifier gives the UI a narrow boundary for one
/// platform-specific presentation rule without mixing availability checks into the main view body.
private struct MenuBarWindowBackgroundModifier: ViewModifier {
    /// Corner radius of the macOS 26 popover window, measured against the system chrome. The opaque
    /// fill is clipped to this so it reaches the rounded edge of the non-opaque window. It is an
    /// intentional coupling to a system measurement: if a future macOS changes the popover shape,
    /// this is the single value to update (too small leaves a transparent sliver that re-detaches
    /// the shadow; too large is harmlessly clipped by the window mask).
    private static let macOS26PopoverCornerRadius: CGFloat = 16

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // macOS 26 Liquid Glass composites `containerBackground(_, for: .window)` through a
            // translucent glass backdrop (a `CABackdropLayer`), so passing it an opaque `Color`
            // does NOT produce an opaque fill: the desktop still bleeds through the glass and the
            // native window shadow detaches from the see-through panel on light backgrounds. That
            // is why #492 (translucent material) recurred as #646 even after #566 swapped the
            // material for an opaque color, which the system still re-routed through the backdrop.
            //
            // Draw the fill as ordinary content instead. A plain `.background` renders as a normal
            // opaque layer rather than the glass backdrop, and we clip it to the native popover
            // shape (see `macOS26PopoverCornerRadius`) so it covers the whole non-opaque window up
            // to the rounded edge. The popup then reads as one solid rounded panel that the system
            // shadow can hug, with no desktop bleed-through.
            content.background {
                RoundedRectangle(cornerRadius: Self.macOS26PopoverCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            }
        } else if #available(macOS 15.0, *) {
            // MenuBarExtra's `.window` style already gives us native rounded window chrome. Place
            // the fill at the hosting window instead of this view's local bounds so it reaches the
            // native rounded frame as one surface (avoids the double-border look fixed in #403).
            // The `.windowBackground` material renders correctly on macOS 15 through pre-26, so
            // keep it there to preserve the vibrant appearance and only patch the 26 regression.
            content.containerBackground(.windowBackground, for: .window)
        } else {
            content
        }
    }
}
