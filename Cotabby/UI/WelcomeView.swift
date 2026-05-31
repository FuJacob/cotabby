import AppKit
import SwiftUI

/// File overview:
/// Renders the first-run onboarding wizard as a guided flow:
/// welcome -> permissions -> choose template -> about you -> writing style -> keybinds -> done.
///
/// Two layout invariants this file protects:
///   1. The Back/Continue footer is pinned outside the scrolling content, so a tall step can never
///      push its own Continue button off-screen (the failure that previously stranded users on the
///      profile step).
///   2. Each middle step shows a progress indicator so the flow reads as finite and "where am I"
///      stays answerable.
///
/// Picking a template applies a curated settings bundle and starts the recommended model download in
/// the background, so it can finish while the user fills out the remaining steps.
struct WelcomeView: View {
    @ObservedObject var permissionManager: PermissionManager
    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    @ObservedObject var modelDownloadManager: ModelDownloadManager
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var foundationModelAvailabilityService: FoundationModelAvailabilityService

    let permissionGuidanceController: PermissionGuidanceController
    let onPreferredWindowSizeChange: (NSSize) -> Void
    let onDismiss: () -> Void

    @State private var step: WelcomeStep = .welcome
    @State private var selectedTemplate: OnboardingTemplate?
    /// The engine chosen at the top of the template step. Seeded in `init` from Apple Intelligence
    /// availability (Apple Intelligence when the Mac supports it, otherwise Open Source) so the
    /// template step's first render already shows the right card instead of flashing the wrong one;
    /// the tier cards resolve their plan against this.
    @State private var selectedEngine: SuggestionEngineKind
    @State private var isRecordingOnboardingKeybind = false
    @State private var isRecordingOnboardingFullAcceptKeybind = false
    @State private var isRecordingOnboardingGlobalToggleKeybind = false

    /// Probed once for the view's lifetime: installed memory and architecture don't change during
    /// onboarding. `@State` (not a stored `let`) ensures `ProcessInfo` is read a single time rather
    /// than on every struct re-creation that an `@ObservedObject` publish (e.g. a download tick) causes.
    @State private var hardware = HardwareCapabilityProbe.current()

    init(
        permissionManager: PermissionManager,
        runtimeModel: RuntimeBootstrapModel,
        modelDownloadManager: ModelDownloadManager,
        suggestionSettings: SuggestionSettingsModel,
        foundationModelAvailabilityService: FoundationModelAvailabilityService,
        permissionGuidanceController: PermissionGuidanceController,
        onPreferredWindowSizeChange: @escaping (NSSize) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        _permissionManager = ObservedObject(wrappedValue: permissionManager)
        _runtimeModel = ObservedObject(wrappedValue: runtimeModel)
        _modelDownloadManager = ObservedObject(wrappedValue: modelDownloadManager)
        _suggestionSettings = ObservedObject(wrappedValue: suggestionSettings)
        _foundationModelAvailabilityService = ObservedObject(wrappedValue: foundationModelAvailabilityService)
        self.permissionGuidanceController = permissionGuidanceController
        self.onPreferredWindowSizeChange = onPreferredWindowSizeChange
        self.onDismiss = onDismiss
        // Seed the engine before the first render so the template step never shows a frame of "Open
        // Source" selected on an Apple Intelligence-capable Mac and then snaps to it. Availability is
        // resolved well before onboarding appears, so reading it here is reliable.
        _selectedEngine = State(
            initialValue: foundationModelAvailabilityService.isAvailable ? .appleIntelligence : .llamaOpenSource
        )
    }

    private var preferredWindowSize: NSSize {
        step.preferredWindowSize
    }

    var body: some View {
        content
            .frame(width: preferredWindowSize.width)
            .background(.ultraThinMaterial)
            .animation(.easeInOut(duration: 0.25), value: preferredWindowSize)
            .onAppear {
                onPreferredWindowSizeChange(preferredWindowSize)
            }
            .onChange(of: preferredWindowSize) { _, newValue in
                onPreferredWindowSizeChange(newValue)
            }
            // When the selected template's model finishes downloading, re-scan disk so the runtime
            // can discover and load it.
            .onChange(of: selectedModelDownloadState) { _, newState in
                guard newState == .downloaded else {
                    return
                }
                modelDownloadManager.refreshModelStates()
                runtimeModel.refreshAvailableModels()
            }
            // Once the chosen model appears in the available list, make it the active runtime model.
            // Doing this reactively (rather than right after kicking the download) avoids racing the
            // asynchronous disk re-scan.
            .onChange(of: runtimeModel.availableModels) { _, models in
                activateChosenModelIfAvailable(in: models)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            terminalLayout { welcomeStep }
        case .done:
            terminalLayout { doneStep }
        default:
            scrollLayout
        }
    }
}

// MARK: - Layout scaffolds

extension WelcomeView {
    /// Compact, centered layout for the intro and outro steps, which are short and never scroll.
    fileprivate func terminalLayout<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            content()
            Spacer(minLength: 0)
        }
        .padding(36)
    }

    /// Scaffold for middle steps: a progress header, scrolling content, and a pinned footer. The
    /// footer stays put while the content scrolls, which is the core fix for "I can't find Continue."
    fileprivate var scrollLayout: some View {
        VStack(spacing: 0) {
            if let progressIndex = step.progressIndex {
                WelcomeStepProgress(current: progressIndex, total: WelcomeStep.totalProgressSteps)
                    .padding(.horizontal, 36)
                    .padding(.top, 28)
                    .padding(.bottom, 6)
            }

            ScrollView {
                stepContent
                    .padding(.horizontal, 36)
                    .padding(.top, step.progressIndex == nil ? 36 : 16)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity)
            }

            stepFooter
                .padding(.horizontal, 36)
                .padding(.top, 8)
                .padding(.bottom, 28)
        }
    }

    @ViewBuilder
    fileprivate var stepContent: some View {
        switch step {
        case .permissions:
            WelcomePermissionStepView(
                permissionManager: permissionManager,
                permissionGuidanceController: permissionGuidanceController
            )
        case .template:
            WelcomeTemplateStepView(
                modelDownloadManager: modelDownloadManager,
                foundationModelAvailabilityService: foundationModelAvailabilityService,
                hardware: hardware,
                selectedEngine: selectedEngine,
                selectedTemplate: $selectedTemplate,
                onSelectEngine: selectEngine,
                onSelect: applyTemplate
            )
        case .aboutYou:
            aboutYouStep
        case .writingStyle:
            writingStyleStep
        case .keybind:
            keybindStep
        case .welcome, .done:
            EmptyView()
        }
    }

    @ViewBuilder
    fileprivate var stepFooter: some View {
        switch step {
        case .permissions:
            WelcomeNavigation(
                canGoBack: true,
                canContinue: permissionManager.requiredPermissionsGranted,
                disabledHint: "Grant all permissions to continue.",
                onBack: { step = .welcome },
                onContinue: { step = .template }
            )
        case .template:
            WelcomeNavigation(
                canGoBack: true,
                canContinue: canContinueFromTemplate,
                disabledHint: templateStepDisabledHint,
                onBack: { step = .permissions },
                onContinue: { step = .aboutYou }
            )
        case .aboutYou:
            WelcomeNavigation(
                canGoBack: true,
                canContinue: true,
                onBack: { step = .template },
                onContinue: { step = .writingStyle }
            )
        case .writingStyle:
            WelcomeNavigation(
                canGoBack: true,
                canContinue: true,
                onBack: { step = .aboutYou },
                onContinue: { step = .keybind }
            )
        case .keybind:
            WelcomeNavigation(
                canGoBack: true,
                canContinue: true,
                onBack: { step = .writingStyle },
                onContinue: { step = .done }
            )
        case .welcome, .done:
            EmptyView()
        }
    }
}

// MARK: - Steps

private enum WelcomeStep: Int, Comparable {
    case welcome
    case permissions
    case template
    case aboutYou
    case writingStyle
    case keybind
    case done

    static func < (lhs: WelcomeStep, rhs: WelcomeStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Number of steps shown in the progress indicator (the middle, non-terminal steps).
    static let totalProgressSteps = 5

    /// 1-based position within the progress indicator, or `nil` for the intro/outro steps that
    /// intentionally sit outside the counted flow.
    var progressIndex: Int? {
        switch self {
        case .welcome, .done:
            return nil
        case .permissions:
            return 1
        case .template:
            return 2
        case .aboutYou:
            return 3
        case .writingStyle:
            return 4
        case .keybind:
            return 5
        }
    }

    /// Product-chosen window sizes. The coordinator clamps the height to the visible screen, and the
    /// scrolling content absorbs any overflow, so these are targets rather than hard guarantees.
    var preferredWindowSize: NSSize {
        switch self {
        case .welcome:
            return NSSize(width: 500, height: 360)
        case .permissions:
            return NSSize(width: 540, height: 540)
        case .template:
            return NSSize(width: 560, height: 640)
        case .aboutYou:
            return NSSize(width: 560, height: 560)
        case .writingStyle:
            return NSSize(width: 560, height: 560)
        case .keybind:
            return NSSize(width: 640, height: 460)
        case .done:
            return NSSize(width: 520, height: 672)
        }
    }
}

// MARK: - Step 1: Welcome

extension WelcomeView {
    fileprivate var welcomeStep: some View {
        VStack(spacing: 24) {
            Image("CotabbyLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(spacing: 8) {
                Text("Welcome to Cotabby")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))

                Text("AI autocomplete in any text field, all done locally.")
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            WelcomeButton(title: "Get Started") {
                step = .permissions
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Step: About You (name + languages)

extension WelcomeView {
    fileprivate var aboutYouStep: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Tell Cotabby about yourself")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))

                Text("This personalizes your suggestions. Everything here is optional.")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name")
                        .font(.system(size: 13, weight: .medium))

                    TextField("What should Cotabby call you?", text: Binding(
                        get: { suggestionSettings.userName },
                        set: { suggestionSettings.setUserName($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                }

                LanguageTagsEditor(suggestionSettings: suggestionSettings)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Step: Writing Style (custom rules)

extension WelcomeView {
    fileprivate var writingStyleStep: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Your writing style")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))

                Text("Add rules to shape tone and style. Skip it and add them later if you'd rather.")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            CustomRulesEditor(suggestionSettings: suggestionSettings)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
    }
}

// MARK: - Step: Keybind

extension WelcomeView {
    fileprivate var keybindStep: some View {
        VStack(spacing: 24) {
            Image(systemName: "keyboard")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("Keybinds")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))

                Text("You can change these later in Settings.")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // 2x2 layout: the two suggestion-acceptance keys stack in the left column, while the
            // opt-in Toggle Tabby hotkey sits on the right. `.top` alignment keeps the left column's
            // first row visually aligned with the single right-column row.
            HStack(alignment: .top, spacing: 32) {
                VStack(spacing: 16) {
                    keybindRow(
                        title: "Accept Word",
                        keyLabel: suggestionSettings.acceptanceKeyLabel,
                        isRecording: $isRecordingOnboardingKeybind,
                        onKeyRecorded: { keyCode, modifiers, label in
                            suggestionSettings.setAcceptanceKey(
                                keyCode: keyCode,
                                modifiers: modifiers,
                                label: label
                            )
                        },
                        onReset: (
                            suggestionSettings.acceptanceKeyCode != SuggestionSettingsModel.defaultAcceptanceKeyCode
                                || !suggestionSettings.acceptanceKeyModifiers.isEmpty
                        ) ? {
                            suggestionSettings.setAcceptanceKey(
                                keyCode: SuggestionSettingsModel.defaultAcceptanceKeyCode,
                                modifiers: [],
                                label: SuggestionSettingsModel.defaultAcceptanceKeyLabel
                            )
                        } : nil
                    )

                    keybindRow(
                        title: "Accept Entire Suggestion",
                        keyLabel: suggestionSettings.fullAcceptanceKeyLabel,
                        isRecording: $isRecordingOnboardingFullAcceptKeybind,
                        onKeyRecorded: { keyCode, modifiers, label in
                            suggestionSettings.setFullAcceptanceKey(
                                keyCode: keyCode,
                                modifiers: modifiers,
                                label: label
                            )
                        },
                        onReset: (
                            suggestionSettings.fullAcceptanceKeyCode != SuggestionSettingsModel.defaultFullAcceptanceKeyCode
                                || !suggestionSettings.fullAcceptanceKeyModifiers.isEmpty
                        ) ? {
                            suggestionSettings.setFullAcceptanceKey(
                                keyCode: SuggestionSettingsModel.defaultFullAcceptanceKeyCode,
                                modifiers: [],
                                label: SuggestionSettingsModel.defaultFullAcceptanceKeyLabel
                            )
                        } : nil
                    )
                }

                // No `onReset` here: the toggle hotkey is opt-in and has no factory default, so the
                // only meaningful "reset" is unbind, which the Clear gesture in the recorder covers.
                keybindRow(
                    title: "Toggle Tabby",
                    keyLabel: suggestionSettings.globalToggleKeyLabel,
                    isRecording: $isRecordingOnboardingGlobalToggleKeybind,
                    onKeyRecorded: { keyCode, modifiers, label in
                        suggestionSettings.setGlobalToggleKey(
                            keyCode: keyCode,
                            modifiers: modifiers,
                            label: label
                        )
                    },
                    onReset: nil
                )
            }
        }
    }

    @ViewBuilder
    fileprivate func keybindRow(
        title: String,
        keyLabel: String,
        isRecording: Binding<Bool>,
        onKeyRecorded: @escaping (CGKeyCode, ShortcutModifierMask, String) -> Void,
        onReset: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text(keyLabel)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.quaternary)
                    )

                if isRecording.wrappedValue {
                    KeyRecorderView(
                        onKeyRecorded: { keyCode, modifiers, label in
                            onKeyRecorded(keyCode, modifiers, label)
                            isRecording.wrappedValue = false
                        },
                        onCancelled: {
                            isRecording.wrappedValue = false
                        }
                    )
                } else {
                    Button("Change") {
                        isRecording.wrappedValue = true
                    }
                }

                if let onReset {
                    Button("Reset") {
                        onReset()
                        isRecording.wrappedValue = false
                    }
                }
            }
        }
    }
}

// MARK: - Step: Done

extension WelcomeView {
    fileprivate var doneStep: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(.green.opacity(0.12))
                    .shadow(color: .green.opacity(0.08), radius: 8, y: 2)

                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.green)
            }
            .frame(width: 64, height: 64)

            VStack(spacing: 8) {
                Text("You're all set")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))

                Text(doneStepSubtitle)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            OnboardingFeatureShowcase()

            doneStepModelStatus

            HStack(spacing: 6) {
                Image(systemName: "menubar.arrow.up.rectangle")
                    .foregroundStyle(.tertiary)

                Text("Find Cotabby in your menu bar.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }

            WelcomeButton(title: "Start Using Cotabby") {
                onDismiss()
            }
            .padding(.top, 4)
        }
    }

    private var doneStepSubtitle: String {
        let wordKey = suggestionSettings.acceptanceKeyLabel
        let fullKey = suggestionSettings.fullAcceptanceKeyLabel
        let hasFullAccept = suggestionSettings.fullAcceptanceKeyCode != SuggestionSettingsModel.disabledKeyCode

        if hasFullAccept {
            return "Start typing anywhere.\nPress \(wordKey) to accept a word, \(fullKey) for the full suggestion."
        }
        return "Start typing anywhere.\nPress \(wordKey) to accept."
    }

    /// A compact reassurance line on the final step when a local model is still downloading or has
    /// finished. Hidden for Apple Intelligence plans, which download nothing.
    @ViewBuilder
    private var doneStepModelStatus: some View {
        switch selectedModelDownloadState {
        case .downloading(let progress):
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                if let progress {
                    Text("Downloading your model… \(Int((progress * 100).rounded()))%")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Downloading your model…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        case .downloaded:
            Label("Your model is ready", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.green)
        case .failed, .idle, .none:
            EmptyView()
        }
    }
}

// MARK: - Template application

extension WelcomeView {
    /// The download state of the currently selected template's model, or `nil` for Apple Intelligence
    /// templates (and before any template is chosen).
    fileprivate var selectedModelDownloadState: ModelDownloadState? {
        guard let template = selectedTemplate else {
            return nil
        }
        let plan = resolvedPlan(for: template)
        guard let model = plan.modelToDownload else {
            return nil
        }
        return modelDownloadManager.state(for: model)
    }

    fileprivate var canContinueFromTemplate: Bool {
        guard let template = selectedTemplate else {
            return false
        }
        let plan = resolvedPlan(for: template)
        switch plan.engine {
        case .appleIntelligence:
            return true
        case .llamaOpenSource:
            // Allow continuing once the download is at least underway; it finishes in the background.
            guard let state = selectedModelDownloadState else {
                return false
            }
            return state == .downloaded || state.isDownloading
        }
    }

    fileprivate var templateStepDisabledHint: String {
        selectedTemplate == nil
            ? "Choose a starting point to continue."
            : "Hang on while your model starts downloading."
    }

    fileprivate func resolvedPlan(for template: OnboardingTemplate) -> ResolvedTemplatePlan {
        OnboardingTemplateRecommender.resolvePlan(for: template, engine: selectedEngine)
    }

    /// Switches the engine. Re-applies the already-selected tier under the new engine so the
    /// persisted settings and any download stay consistent; switching to Open Source after a tier
    /// is chosen starts that tier's download (the tap is the user's consent), while Apple
    /// Intelligence needs none. No download is started until a tier has been chosen.
    fileprivate func selectEngine(_ engine: SuggestionEngineKind) {
        guard selectedEngine != engine else {
            return
        }
        selectedEngine = engine
        if let template = selectedTemplate {
            applyTemplate(template)
        }
    }

    /// Applies a template's settings and starts its model download (if any). Selecting a card is the
    /// user's explicit consent to download, so a multi-gigabyte fetch only ever starts from here.
    fileprivate func applyTemplate(_ template: OnboardingTemplate) {
        selectedTemplate = template

        let plan = resolvedPlan(for: template)
        suggestionSettings.selectEngine(plan.engine)
        suggestionSettings.selectWordCountPreset(plan.wordCountPreset)
        suggestionSettings.setFastModeEnabled(plan.enablesFastMode)
        suggestionSettings.setMultiLineEnabled(plan.enablesMultiLine)

        guard let model = plan.modelToDownload else {
            return
        }

        if modelDownloadManager.isModelInstalled(filename: model.filename) {
            // Already on disk (e.g. re-running onboarding): make sure the runtime can see and load it.
            modelDownloadManager.refreshModelStates()
            runtimeModel.refreshAvailableModels()
        } else {
            modelDownloadManager.download(model)
        }
    }

    /// Selects the chosen template's model as the active runtime model once it shows up in the
    /// available list. No-ops for Apple Intelligence plans and when it is already selected.
    fileprivate func activateChosenModelIfAvailable(in models: [RuntimeModelOption]) {
        guard let template = selectedTemplate else {
            return
        }
        guard let filename = resolvedPlan(for: template).modelToDownload?.filename else {
            return
        }
        guard models.contains(where: { $0.filename == filename }) else {
            return
        }
        guard runtimeModel.selectedModelFilename != filename else {
            return
        }

        Task {
            await runtimeModel.selectModel(filename)
        }
    }
}

// MARK: - Progress indicator

/// A small "Step X of Y" row with filled capsule pips, shown on the middle steps so the flow reads
/// as finite and the user always knows how far along they are.
private struct WelcomeStepProgress: View {
    let current: Int
    let total: Int

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(1...total, id: \.self) { index in
                    Capsule()
                        .fill(index <= current ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: index == current ? 22 : 16, height: 5)
                        .animation(.easeInOut(duration: 0.2), value: current)
                }
            }

            Text("Step \(current) of \(total)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current) of \(total)")
    }
}

// MARK: - Shared Components

/// Primary action button used on the welcome and done steps.
struct WelcomeButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

/// Continue navigation bar for middle wizard steps.
/// "Continue" can be disabled with a tooltip hint explaining what's needed.
struct WelcomeNavigation: View {
    var canGoBack: Bool = false
    var canContinue: Bool = true
    var disabledHint: String?
    var onBack: (() -> Void)?
    let onContinue: () -> Void

    var body: some View {
        HStack {
            if canGoBack, let onBack {
                Button("Back") {
                    onBack()
                }
                .controlSize(.large)
            }

            Spacer(minLength: 0)

            Button("Continue") {
                onContinue()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canContinue)
            .help(canContinue ? "" : (disabledHint ?? ""))
        }
    }
}
