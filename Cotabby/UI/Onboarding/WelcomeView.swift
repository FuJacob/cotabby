import AppKit
import SwiftUI

/// File overview:
/// Renders the first-run onboarding wizard as a guided flow:
/// welcome -> permissions -> choose starting point -> personalize -> keys -> done.
///
/// Design intent: this is the first thing a new user sees, so it leads with the product (a live
/// ghost-text demo on the very first screen) before it asks for anything, and every step shares
/// one visual vocabulary from `OnboardingStyle` (brand-blue backdrop, tinted icon tiles, card
/// chrome, staggered reveals). Steps slide horizontally like Setup Assistant pages; the window
/// keeps one width and only morphs vertically (see `WelcomeStep.preferredWindowSize`).
///
/// Two layout invariants this file protects:
///   1. The Back/Continue footer is pinned outside the scrolling content, so a tall step can never
///      push its own Continue button off-screen (the failure that previously stranded users on the
///      profile step).
///   2. Each middle step shows a progress indicator so the flow reads as finite and "where am I"
///      stays answerable.
///
/// Picking a template applies a curated settings bundle and starts the recommended model download
/// in the background, so it can finish while the user fills out the remaining steps.
struct WelcomeView: View {
    @ObservedObject var permissionManager: PermissionManager
    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    @ObservedObject var modelDownloadManager: ModelDownloadManager
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var foundationModelAvailabilityService: FoundationModelAvailabilityService

    let permissionGuidanceController: PermissionGuidanceController
    let onPreferredWindowSizeChange: (NSSize) -> Void
    let onDismiss: () -> Void
    /// Reports the current step's raw index up to the coordinator so it can persist a resume point.
    /// The wizard is re-shown from this step if the user is pulled out before finishing (see #314).
    let onStepChange: (Int) -> Void
    /// True when this user has completed a prior onboarding version. The Custom path keeps the
    /// user's existing settings instead of overwriting them with template defaults, since they have
    /// already tuned Cotabby; advancing via "Set up later" preserves that.
    let isReturningUser: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: WelcomeStep
    /// Whether the most recent navigation moved deeper into the flow. Read by `pageTransition` so
    /// pages slide in from the side the user is heading toward, and back out the way they came.
    @State private var navigatesForward = true
    @State private var selectedTemplate: OnboardingTemplate?
    /// The engine chosen at the top of the template step. Seeded in `init` from Apple Intelligence
    /// availability (Apple Intelligence when the Mac supports it, otherwise Open Source) so the
    /// template step's first render already shows the right card instead of flashing the wrong one;
    /// the tier cards resolve their plan against this.
    @State private var selectedEngine: SuggestionEngineKind

    /// Probed once for the view's lifetime: installed memory and architecture don't change during
    /// onboarding. `@State` (not a stored `let`) ensures `ProcessInfo` is read a single time rather
    /// than on every struct re-creation that an `@ObservedObject` publish (e.g. a download tick)
    /// causes.
    @State private var hardware = HardwareCapabilityProbe.current()

    init(
        permissionManager: PermissionManager,
        runtimeModel: RuntimeBootstrapModel,
        modelDownloadManager: ModelDownloadManager,
        suggestionSettings: SuggestionSettingsModel,
        foundationModelAvailabilityService: FoundationModelAvailabilityService,
        permissionGuidanceController: PermissionGuidanceController,
        onPreferredWindowSizeChange: @escaping (NSSize) -> Void,
        onDismiss: @escaping () -> Void,
        initialStepIndex: Int = 0,
        isReturningUser: Bool = false,
        onStepChange: @escaping (Int) -> Void = { _ in }
    ) {
        self.isReturningUser = isReturningUser
        _permissionManager = ObservedObject(wrappedValue: permissionManager)
        _runtimeModel = ObservedObject(wrappedValue: runtimeModel)
        _modelDownloadManager = ObservedObject(wrappedValue: modelDownloadManager)
        _suggestionSettings = ObservedObject(wrappedValue: suggestionSettings)
        _foundationModelAvailabilityService = ObservedObject(wrappedValue: foundationModelAvailabilityService)
        self.permissionGuidanceController = permissionGuidanceController
        self.onPreferredWindowSizeChange = onPreferredWindowSizeChange
        self.onDismiss = onDismiss
        self.onStepChange = onStepChange
        // Resume at the furthest step the user previously reached. An out-of-range or absent value
        // (0) falls back to `.welcome`, so brand-new users still start at the beginning.
        _step = State(initialValue: WelcomeStep(rawValue: initialStepIndex) ?? .welcome)
        // Seed the engine before the first render so the template step never shows a frame of "Open
        // Source" selected on an Apple Intelligence-capable Mac and then snaps to it. Availability
        // is resolved well before onboarding appears, so reading it here is reliable.
        _selectedEngine = State(
            initialValue: foundationModelAvailabilityService.isAvailable ? .appleIntelligence : .llamaOpenSource
        )
    }

    private var preferredWindowSize: NSSize {
        step.preferredWindowSize
    }

    var body: some View {
        VStack(spacing: 0) {
            if let progressIndex = step.progressIndex {
                OnboardingProgressPips(current: progressIndex, total: WelcomeStep.totalProgressSteps)
                    .padding(.top, 26)
                    .transition(.opacity)
            }

            ZStack {
                page
                    .id(step)
                    .transition(pageTransition)
            }
        }
        .frame(width: WelcomeStep.windowWidth)
        .background(OnboardingBackdrop())
        .onAppear {
            onPreferredWindowSizeChange(preferredWindowSize)
            // Stamp the resume point for the step we open on. Matters when resuming directly onto
            // a later step: without this, quitting again before advancing would not re-persist it.
            onStepChange(step.rawValue)
        }
        .onChange(of: step) { _, newStep in
            onStepChange(newStep.rawValue)
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
}

// MARK: - Navigation

extension WelcomeView {
    /// All step changes flow through here so the slide direction and the spring are decided in one
    /// place. Reduce Motion swaps pages with no animation at all (the transition never plays).
    fileprivate func go(to newStep: WelcomeStep) {
        navigatesForward = newStep > step
        guard !reduceMotion else {
            step = newStep
            return
        }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
            step = newStep
        }
    }

    /// Pages push in from the direction of travel, Setup Assistant style. `navigatesForward` is
    /// set before the animated `step` write, so both the inserted and removed page agree on it.
    fileprivate var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: navigatesForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: navigatesForward ? .leading : .trailing).combined(with: .opacity)
        )
    }
}

// MARK: - Pages

extension WelcomeView {
    @ViewBuilder
    fileprivate var page: some View {
        switch step {
        case .welcome:
            welcomePage
        case .done:
            donePage
        case .permissions, .template, .personalize, .keybind:
            // Scaffold for middle steps: scrolling content above a pinned footer. The footer stays
            // put while the content scrolls, which is the core fix for "I can't find Continue."
            VStack(spacing: 0) {
                ScrollView {
                    stepContent
                        .padding(.horizontal, OnboardingLayout.horizontalPadding)
                        .padding(.top, 18)
                        .padding(.bottom, 16)
                        .frame(maxWidth: .infinity)
                }

                stepFooter
                    .padding(.horizontal, OnboardingLayout.horizontalPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 26)
            }
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
        case .personalize:
            WelcomePersonalizeStepView(suggestionSettings: suggestionSettings)
        case .keybind:
            WelcomeKeybindStepView(suggestionSettings: suggestionSettings)
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
                onBack: { go(to: .welcome) },
                onContinue: { go(to: .template) }
            )
        case .template:
            WelcomeNavigation(
                canGoBack: true,
                canContinue: canContinueFromTemplate,
                // With no curated tier chosen, the primary button becomes "Set up later" and applies
                // the neutral Custom path under the hood, so the user is never blocked on a card.
                continueTitle: selectedTemplate == nil ? "Set up later" : "Continue",
                disabledHint: templateStepDisabledHint,
                onBack: { go(to: .permissions) },
                onContinue: {
                    if selectedTemplate == nil {
                        applyTemplate(.custom)
                    }
                    go(to: .personalize)
                }
            )
        case .personalize:
            WelcomeNavigation(
                canGoBack: true,
                canContinue: !suggestionSettings.responseLanguages.isEmpty,
                disabledHint: "Add at least one language so Cotabby knows what to write in.",
                onBack: { go(to: .template) },
                onContinue: { go(to: .keybind) }
            )
        case .keybind:
            WelcomeNavigation(
                canGoBack: true,
                canContinue: true,
                onBack: { go(to: .personalize) },
                onContinue: { go(to: .done) }
            )
        case .welcome, .done:
            EmptyView()
        }
    }
}

// MARK: - Step 1: Welcome

extension WelcomeView {
    fileprivate var welcomePage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 24) {
                Image("CotabbyLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                    .shadow(color: CotabbyBrand.accent.opacity(0.45), radius: 22, y: 8)
                    .onboardingReveal(0)

                VStack(spacing: 8) {
                    Text("Welcome to Cotabby")
                        .font(.system(size: 30, weight: .bold, design: .rounded))

                    Text("Ghost-text autocomplete in every app,\ngenerated entirely on your Mac.")
                        .font(.system(size: 15, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .onboardingReveal(1)

                WelcomeHeroDemo()
                    .frame(maxWidth: 440)
                    .onboardingReveal(2)

                HStack(spacing: 8) {
                    WelcomeFeatureChip(systemImage: "lock.fill", label: "100% on-device")
                    WelcomeFeatureChip(systemImage: "chevron.left.forwardslash.chevron.right", label: "Open source")
                    WelcomeFeatureChip(systemImage: "macwindow", label: "Works everywhere")
                }
                .onboardingReveal(3)

                WelcomeButton(title: "Get Started") {
                    go(to: .permissions)
                }
                .padding(.top, 4)
                .onboardingReveal(4)
            }

            Spacer(minLength: 0)
        }
        .padding(36)
    }
}

/// Small capsule highlighting one of Cotabby's differentiators on the welcome screen.
private struct WelcomeFeatureChip: View {
    let systemImage: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CotabbyBrand.accent)

            Text(label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

// MARK: - Step: Done

extension WelcomeView {
    fileprivate var donePage: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    doneHero
                        .onboardingReveal(0)

                    VStack(spacing: 8) {
                        Text("You're all set")
                            .font(.system(size: 28, weight: .bold, design: .rounded))

                        Text(doneStepSubtitle)
                            .font(.system(size: 15, design: .rounded))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .onboardingReveal(1)

                    menuBarCallout
                        .onboardingReveal(2)

                    OnboardingFeatureShowcase()
                        .onboardingReveal(3)
                }
                .padding(.horizontal, OnboardingLayout.horizontalPadding)
                .padding(.top, 40)
                .padding(.bottom, 16)
            }

            VStack(spacing: 12) {
                doneStepModelStatus

                WelcomeButton(title: "Start Using Cotabby") {
                    onDismiss()
                }
            }
            .padding(.horizontal, OnboardingLayout.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 26)
            .onboardingReveal(4)
        }
    }

    /// The completion mark: a lit-from-above green seal, sized to land as the step's reward.
    private var doneHero: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.green.opacity(0.8), Color.green],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: .green.opacity(0.4), radius: 18, y: 6)

            Image(systemName: "checkmark")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 72, height: 72)
    }

    /// Menu bar discovery is the single most important thing to leave the user with: people who
    /// can't find the app after the window closes assume it isn't running. So it gets a real card,
    /// not a footnote.
    private var menuBarCallout: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(0.55))

                Image("MenuBarCatIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 18)
                    .foregroundStyle(.primary)
            }
            .frame(width: 44, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text("Cotabby lives in your menu bar")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))

                Text("Click the cat to pause suggestions, switch models, or open Settings.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .onboardingCard(cornerRadius: 12)
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
    /// The download state of the currently selected template's model, or `nil` for Apple
    /// Intelligence templates (and before any template is chosen).
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

    /// Whether the template step's primary button is enabled. With no tier chosen it is always
    /// enabled: the button reads "Set up later" and applies the neutral Custom path. With a tier
    /// chosen, Apple Intelligence is immediately ready, while Open Source waits until that tier's
    /// model download has at least started (it finishes in the background).
    fileprivate var canContinueFromTemplate: Bool {
        guard let template = selectedTemplate else {
            return true
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

    /// Tooltip for the disabled primary button. Only reachable once a tier is chosen but its Open
    /// Source download hasn't started yet — with no tier chosen the button is "Set up later" and
    /// always enabled, so there is no longer a "pick something" hint.
    fileprivate var templateStepDisabledHint: String {
        "Hang on while your model starts downloading."
    }

    fileprivate func resolvedPlan(for template: OnboardingTemplate) -> ResolvedTemplatePlan {
        let base = OnboardingTemplateRecommender.resolvePlan(for: template, engine: selectedEngine)
        // Returning users on the Custom path with the OSS engine keep their currently selected local
        // model instead of the static template default, so the done-step status and model activation
        // reflect the settings applyTemplate actually preserves for them.
        guard
            template == .custom,
            isReturningUser,
            selectedEngine == .llamaOpenSource,
            let currentFilename = runtimeModel.selectedModelFilename,
            currentFilename != base.modelToDownload?.filename,
            let currentModel = RuntimeModelCatalog.downloadableModels.first(where: { $0.filename == currentFilename })
        else {
            return base
        }
        return ResolvedTemplatePlan(
            template: base.template,
            engine: base.engine,
            modelToDownload: currentModel,
            wordCountPreset: base.wordCountPreset,
            enablesFastMode: base.enablesFastMode,
            enablesMultiLine: base.enablesMultiLine,
            enablesClipboardContext: base.enablesClipboardContext
        )
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

    /// Applies a template's settings and starts its model download (if any). Choosing a tier card —
    /// or taking the "Set up later" path, which applies `.custom` — is the user's explicit consent
    /// to download, so a multi-gigabyte fetch only ever starts from here.
    fileprivate func applyTemplate(_ template: OnboardingTemplate) {
        selectedTemplate = template

        // Returning users on the Custom path keep every setting they previously tuned. Skipping the
        // writes here (and the model download below) preserves their engine, word count, behavior
        // toggles, and avoids re-triggering a multi-gigabyte fetch they already completed.
        if template == .custom && isReturningUser {
            return
        }

        let plan = resolvedPlan(for: template)
        suggestionSettings.selectEngine(plan.engine)
        suggestionSettings.selectWordCountPreset(plan.wordCountPreset)
        suggestionSettings.setFastModeEnabled(plan.enablesFastMode)
        suggestionSettings.setMultiLineEnabled(plan.enablesMultiLine)
        suggestionSettings.setClipboardContextEnabled(plan.enablesClipboardContext)

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
