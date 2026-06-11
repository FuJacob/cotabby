import Combine
import Foundation
import Logging

/// File overview:
/// Builds Cotabby's long-lived dependency graph in one place. This is the app's composition model:
/// services are constructed once here, then handed to `AppDelegate` and the UI as shared owners.
///
/// In frontend terms, this plays the role of a top-level dependency container or provider tree.
/// The important architectural idea is that creation happens in one place, while usage happens
/// elsewhere. That keeps lifecycle ownership easy to follow.
@MainActor
final class CotabbyAppEnvironment {
    let permissionManager: PermissionManager
    let runtimeModel: RuntimeBootstrapModel
    let modelDownloadManager: ModelDownloadManager
    let focusModel: FocusTrackingModel
    let inputMonitor: InputMonitor
    let appUpdateManager: AppUpdateManager
    let permissionGuidanceController: PermissionGuidanceController
    let suggestionSettings: SuggestionSettingsModel
    let foundationModelAvailabilityService: FoundationModelAvailabilityService
    let powerSourceMonitor: PowerSourceMonitor
    /// Detects when a composing input method (Japanese kana, Chinese pinyin, Korean hangul, ...) is
    /// active so `SuggestionInserter` commits accepted text through an IME-safe path instead of a
    /// synthetic keystroke the input method would swallow. See `KeyboardInputSourceMonitor`.
    let keyboardInputSourceMonitor: KeyboardInputSourceMonitor
    let clipboardContextProvider: ClipboardContextProvider
    let suggestionCoordinator: SuggestionCoordinator
    let emojiPickerController: EmojiPickerController
    let macroController: MacroController
    let inlineCommandCoordinator: InlineCommandCoordinator
    let emojiUsageStore: EmojiUsageStore
    let welcomeCoordinator: WelcomeCoordinator
    let huggingFaceSearchService: HuggingFaceSearchService
    let performanceMetricsStore: PerformanceMetricsStore
    let settingsCoordinator: SettingsCoordinator
    let activationIndicatorController: ActivationIndicatorController
    let focusDebugOverlayController: FocusDebugOverlayController?

    private var cancellables = Set<AnyCancellable>()

    init() {
        CotabbyLogger.app.info("Building dependency graph")
        let configuration = SuggestionConfiguration.standard
        let permissionManager = PermissionManager()
        let permissionGuidanceController = PermissionGuidanceController(
            permissionManager: permissionManager
        )
        let runtimeManager = LlamaRuntimeManager()
        let runtimeModel = RuntimeBootstrapModel(runtimeManager: runtimeManager)
        let modelDownloadManager = ModelDownloadManager()
        let suggestionSettings = SuggestionSettingsModel(configuration: configuration)
        let foundationModelAvailabilityService = FoundationModelAvailabilityService()
        let powerSourceMonitor = PowerSourceMonitor()
        let keyboardInputSourceMonitor = KeyboardInputSourceMonitor()
        let suppressionController = InputSuppressionController()
        let inputMonitor = InputMonitor(
            permissionProvider: { permissionManager.inputMonitoringGranted },
            suppressionController: suppressionController
        )
        inputMonitor.acceptanceKeyCodeProvider = { suggestionSettings.acceptanceKeyCode }
        inputMonitor.acceptanceKeyModifiersProvider = { suggestionSettings.acceptanceKeyModifiers }
        inputMonitor.fullAcceptanceKeyCodeProvider = { suggestionSettings.fullAcceptanceKeyCode }
        inputMonitor.fullAcceptanceKeyModifiersProvider = { suggestionSettings.fullAcceptanceKeyModifiers }
        inputMonitor.globalToggleKeyCodeProvider = { suggestionSettings.globalToggleKeyCode }
        inputMonitor.globalToggleKeyModifiersProvider = { suggestionSettings.globalToggleKeyModifiers }
        inputMonitor.onGlobalToggleHotkey = { [weak suggestionSettings] in
            suggestionSettings?.toggleGloballyEnabled()
        }
        // Stop the deep AX walk when Cotabby is disabled for the focused app. Without this the
        // focus poll keeps enumerating the frontmost app's AX attributes every 50-80ms even after
        // the user toggles Cotabby off, which can dismiss transient popovers in apps like Calendar
        // (#476). Gating here also makes the "I disabled it but the bug remained" symptom go away:
        // the disable toggles now actually stop touching the focused app.
        let focusModel = FocusTrackingModel(
            permissionProvider: { permissionManager.accessibilityGranted },
            ignoredBundleIdentifier: Bundle.main.bundleIdentifier,
            // The Context pane's live-preview field is the single sanctioned spot where Cotabby may
            // complete inside its own UI; the focus tracker recognises it by this AX identifier.
            selfCaptureAllowedElementIdentifier: ContextLivePreview.accessibilityIdentifier,
            isCaptureSuppressedForBundle: { bundleIdentifier in
                guard suggestionSettings.isGloballyEnabled else { return true }
                if let bundleIdentifier,
                   suggestionSettings.isApplicationDisabled(bundleIdentifier: bundleIdentifier) {
                    return true
                }
                return false
            },
            publishesPollingEvents: FocusDebugOverlayController.isEnabled
        )
        // The snapshot is poll-based, so after a fast app switch the closure may briefly
        // evaluate against the previous app's identity until the next AX poll fires. This
        // is the same race the downstream evaluator already has — not a new regression.
        inputMonitor.shouldProcessEventsProvider = { [weak focusModel] in
            guard suggestionSettings.isGloballyEnabled else { return false }
            guard let snapshot = focusModel?.snapshot else { return true }
            if TerminalAppDetector.isTerminal(bundleIdentifier: snapshot.bundleIdentifier) { return false }
            if let bundleID = snapshot.bundleIdentifier,
               suggestionSettings.isApplicationDisabled(bundleIdentifier: bundleID) {
                return false
            }
            return true
        }
        let appUpdateManager = AppUpdateManager()
        let welcomeCoordinator = WelcomeCoordinator(
            permissionManager: permissionManager,
            permissionGuidanceController: permissionGuidanceController,
            runtimeModel: runtimeModel,
            modelDownloadManager: modelDownloadManager,
            suggestionSettings: suggestionSettings,
            foundationModelAvailabilityService: foundationModelAvailabilityService
        )
        let huggingFaceSearchService = HuggingFaceSearchService()
        let performanceMetricsStore = PerformanceMetricsStore()
        // Live CPU/RAM graph backing for the Performance pane. Holds no state until the pane asks it
        // to start sampling, so constructing it eagerly here costs nothing.
        let systemMetricsStore = SystemMetricsStore()
        let suggestionInserter = SuggestionInserter(suppressionController: suppressionController)
        // Commit accepted text through an IME-safe path (Accessibility / paste) while a composing IME
        // is active; a synthetic keystroke would be re-absorbed into composition and the accept would
        // silently fail.
        suggestionInserter.isComposingIMEActiveProvider = { [weak keyboardInputSourceMonitor] in
            keyboardInputSourceMonitor?.isComposingIMEActive ?? false
        }
        let overlayController = OverlayController(suggestionSettings: suggestionSettings)
        let activationIndicatorController = ActivationIndicatorController()
        let clipboardContextProvider = ClipboardContextProvider()
        let clipboardRelevanceFilter = ClipboardRelevanceFilter()
        let screenshotContextGenerator = ScreenshotContextGenerator()
        let visualContextCoordinator = VisualContextCoordinator(
            screenshotContextGenerator: screenshotContextGenerator,
            screenRecordingPermissionProvider: { permissionManager.screenRecordingGranted }
        )
        let foundationModelEngine: any SuggestionGenerating
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            foundationModelEngine = FoundationModelSuggestionEngine(
                availabilityService: foundationModelAvailabilityService
            )
            CotabbyLogger.app.info("Foundation model engine available")
        } else {
            foundationModelEngine = UnavailableSuggestionEngine(
                message: foundationModelAvailabilityService.userVisibleMessage
            )
            CotabbyLogger.app.info("Foundation model engine unavailable (macOS version)")
        }
        #else
        foundationModelEngine = UnavailableSuggestionEngine(
            message: foundationModelAvailabilityService.userVisibleMessage
        )
        CotabbyLogger.app.info("Foundation model engine unavailable (SDK)")
        #endif

        let suggestionEngine: any SuggestionGenerating = SuggestionEngineRouter(
            suggestionSettings: suggestionSettings,
            foundationModelEngine: foundationModelEngine,
            llamaEngine: LlamaSuggestionEngine(runtimeManager: runtimeManager),
            performanceMetricsStore: performanceMetricsStore,
            llamaModelNameProvider: { [weak runtimeManager] in
                runtimeManager?.currentModelFilename
            }
        )

        // Per-user emoji recents/frequency. Built before the settings coordinator so the
        // "Clear History" control can reach it, and before the picker which reads and writes it.
        let emojiUsageStore = EmojiUsageStore()

        let settingsCoordinator = SettingsCoordinator(
            appUpdateManager: appUpdateManager,
            permissionManager: permissionManager,
            permissionGuidanceController: permissionGuidanceController,
            suggestionSettings: suggestionSettings,
            foundationModelAvailabilityService: foundationModelAvailabilityService,
            runtimeModel: runtimeModel,
            modelDownloadManager: modelDownloadManager,
            huggingFaceSearchService: huggingFaceSearchService,
            performanceMetricsStore: performanceMetricsStore,
            systemMetricsStore: systemMetricsStore,
            onShowWelcome: { [weak welcomeCoordinator] in
                welcomeCoordinator?.showWelcome()
            },
            clearEmojiHistory: { emojiUsageStore.clear() }
        )

        let interactionState = SuggestionInteractionState()
        let workController = SuggestionWorkController()
        // Constructed once at app scope so the underlying `NSSpellChecker` document tag survives
        // across coordinator state transitions instead of churning per keystroke.
        let spellChecker = CurrentWordSpellChecker()
        let enabledSpellingLanguages = SpellingDictionaryCatalog.languages(
            for: suggestionSettings.enabledSpellingDictionaryCodes
        )
        // Preserve the existing warm English path when it is enabled. A sole non-English choice is
        // also preloaded; broader multilingual sets stay lazy so app launch never builds every index.
        let preloadSpellingLanguage = enabledSpellingLanguages.count == 1
            ? enabledSpellingLanguages.first
            : enabledSpellingLanguages.first(where: { $0 == .english })
        let symSpellCorrector = SymSpellCorrector(
            preloadLanguage: preloadSpellingLanguage
        )
        let suggestionCoordinator = SuggestionCoordinator(
            permissionManager: permissionManager,
            focusModel: focusModel,
            inputMonitor: inputMonitor,
            overlayController: overlayController,
            suggestionInserter: suggestionInserter,
            suggestionEngine: suggestionEngine,
            suggestionSettings: suggestionSettings,
            clipboardContextProvider: clipboardContextProvider,
            clipboardRelevanceFilter: clipboardRelevanceFilter,
            visualContextCoordinator: visualContextCoordinator,
            interactionState: interactionState,
            workController: workController,
            configuration: configuration,
            spellChecker: spellChecker,
            symSpellCorrector: symSpellCorrector,
            spellingLanguageResolver: SpellingLanguageResolver()
        )

        // The emoji picker is a sibling to the suggestion coordinator. It reuses the input monitor,
        // focus model, and inserter, but owns its own trigger state machine and floating panel.
        let emojiPickerController = EmojiPickerController(
            matcher: EmojiMatcher(catalog: EmojiCatalog.bundled()),
            panel: EmojiPickerPanelController(),
            focusModel: focusModel,
            inputMonitor: inputMonitor,
            inserter: suggestionInserter,
            isEnabled: { suggestionSettings.isEmojiPickerEnabled },
            emojiPreferences: { suggestionSettings.emojiVariantPreferences },
            acceptKeyLabel: { suggestionSettings.emojiPickerAcceptKeyLabel },
            emojiUsage: { emojiUsageStore.snapshot() },
            recordEmojiUsage: { emojiUsageStore.record(alias: $0) }
        )
        // The macro preview is a second inline-command provider, on the `/` sigil. It reuses the same
        // input monitor, focus model, and inserter as the emoji picker, and renders a single-row
        // preview near the caret.
        let macroController = MacroController(
            engine: MacroEngine.standard(),
            panel: InlinePreviewPanelController(),
            focusModel: focusModel,
            inserter: suggestionInserter,
            isEnabled: { suggestionSettings.isMacroExpansionEnabled },
            acceptKeyLabel: { suggestionSettings.emojiPickerAcceptKeyLabel },
            isWordAcceptKey: { inputMonitor.isWordAcceptKey($0) }
        )
        // One coordinator fans every keystroke out to both inline-command controllers and owns the
        // input monitor's single capture decider and interception flag, which the `:` and `/` features
        // share. It is given first look at every keystroke the suggestion coordinator receives.
        let inlineCommandCoordinator = InlineCommandCoordinator(
            emoji: emojiPickerController,
            macro: macroController,
            inputMonitor: inputMonitor
        )
        suggestionCoordinator.emojiInputObserver = { [weak inlineCommandCoordinator] event in
            inlineCommandCoordinator?.observe(event) ?? false
        }

        self.permissionManager = permissionManager
        self.runtimeModel = runtimeModel
        self.modelDownloadManager = modelDownloadManager
        self.focusModel = focusModel
        self.inputMonitor = inputMonitor
        self.appUpdateManager = appUpdateManager
        self.permissionGuidanceController = permissionGuidanceController
        self.suggestionSettings = suggestionSettings
        self.foundationModelAvailabilityService = foundationModelAvailabilityService
        self.powerSourceMonitor = powerSourceMonitor
        self.keyboardInputSourceMonitor = keyboardInputSourceMonitor
        self.clipboardContextProvider = clipboardContextProvider
        self.suggestionCoordinator = suggestionCoordinator
        self.emojiPickerController = emojiPickerController
        self.macroController = macroController
        self.inlineCommandCoordinator = inlineCommandCoordinator
        self.emojiUsageStore = emojiUsageStore
        self.welcomeCoordinator = welcomeCoordinator
        self.huggingFaceSearchService = huggingFaceSearchService
        self.performanceMetricsStore = performanceMetricsStore
        self.settingsCoordinator = settingsCoordinator
        self.activationIndicatorController = activationIndicatorController
        self.focusDebugOverlayController = FocusDebugOverlayController.isEnabled
            ? FocusDebugOverlayController()
            : nil

        // Update the AX polling timer whenever the user changes the poll interval setting.
        suggestionSettings.$focusPollIntervalMilliseconds
            .removeDuplicates()
            .sink { [weak focusModel] milliseconds in
                focusModel?.updatePollInterval(milliseconds: milliseconds)
            }
            .store(in: &cancellables)

        // Key code changes reach InputMonitor through closures that read from the model
        // at event time (set above), so no Combine subscription is needed here.

        // The global-toggle hotkey is the exception: its tap is install-on-demand so a user who
        // never binds it pays zero per-keystroke cost. Install/uninstall whenever the binding
        // crosses the unbound/bound boundary or when the key code itself changes.
        suggestionSettings.$globalToggleKeyCode
            .removeDuplicates()
            .sink { [weak inputMonitor] _ in
                inputMonitor?.refreshToggleTap()
            }
            .store(in: &cancellables)

        observePowerSourceProfileSwitching()
    }

    /// Applies the user's per-power-source profile (engine + model) whenever anything that could
    /// change the right answer changes: the power source, the feature toggle, either profile, or the
    /// installed-model list (so a profile referencing a still-loading model is honored once it
    /// appears). The apply step is idempotent (`selectEngine`/`selectModel` no-op when already
    /// current), so the redundant values `@Published` replays on subscription are harmless.
    /// Extracted from `init` to keep the initializer's complexity bounded.
    private func observePowerSourceProfileSwitching() {
        let triggers: [AnyPublisher<Void, Never>] = [
            powerSourceMonitor.$isPluggedIn.map { _ in () }.eraseToAnyPublisher(),
            suggestionSettings.$isPowerBasedModelSwitchingEnabled.map { _ in () }.eraseToAnyPublisher(),
            suggestionSettings.$batteryEngine.map { _ in () }.eraseToAnyPublisher(),
            suggestionSettings.$batteryModelFilename.map { _ in () }.eraseToAnyPublisher(),
            suggestionSettings.$pluggedInEngine.map { _ in () }.eraseToAnyPublisher(),
            suggestionSettings.$pluggedInModelFilename.map { _ in () }.eraseToAnyPublisher(),
            runtimeModel.$availableModels.map { _ in () }.eraseToAnyPublisher()
        ]

        Publishers.MergeMany(triggers)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }

                Self.applyPowerProfile(
                    isPluggedIn: self.powerSourceMonitor.isPluggedIn,
                    runtimeModel: self.runtimeModel,
                    suggestionSettings: self.suggestionSettings,
                    availability: self.foundationModelAvailabilityService
                )
            }
            .store(in: &cancellables)
    }

    /// Switches the active engine (and, for Open Source, the model) to the profile configured for the
    /// current power source. Does nothing when the feature is off. Apple Intelligence is applied only
    /// when actually available, so a configured-but-unavailable profile never strands the user on a
    /// dead engine; the Open Source branch reloads the model only when it is installed and not already
    /// selected, so the sole side effect is a deliberate reload on a real change.
    private static func applyPowerProfile(
        isPluggedIn: Bool,
        runtimeModel: RuntimeBootstrapModel,
        suggestionSettings: SuggestionSettingsModel,
        availability: FoundationModelAvailabilityService
    ) {
        guard suggestionSettings.isPowerBasedModelSwitchingEnabled else {
            return
        }

        let profile = isPluggedIn ? suggestionSettings.pluggedInProfile : suggestionSettings.batteryProfile

        switch profile {
        case .appleIntelligence:
            guard availability.isAvailable else {
                return
            }

            suggestionSettings.selectEngine(.appleIntelligence)

        case .llama(let filename):
            suggestionSettings.selectEngine(.llamaOpenSource)

            guard !filename.isEmpty,
                  runtimeModel.availableModels.contains(where: { $0.filename == filename }),
                  runtimeModel.selectedModelFilename != filename else {
                return
            }

            Task {
                await runtimeModel.selectModel(filename)
            }
        }
    }
}
