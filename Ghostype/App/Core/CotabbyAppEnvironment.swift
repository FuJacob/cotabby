import Combine
import Foundation
import Logging

/// File overview:
/// Builds Ghostype's long-lived dependency graph in one place. This is the app's composition model:
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
    /// Temporarily pauses Calendar AX traversal only while its date/time editor is active.
    let calendarAccessibilityCaptureGuard: CalendarAccessibilityCaptureGuard
    let appUpdateManager: AppUpdateManager
    let permissionGuidanceController: PermissionGuidanceController
    let suggestionSettings: SuggestionSettingsModel
    let openAICompatibleConnectionModel: OpenAICompatibleConnectionModel
    let foundationModelAvailabilityService: FoundationModelAvailabilityService
    let powerSourceMonitor: PowerSourceMonitor
    /// Process-lifetime Low Power Mode observer shared with suggestion orchestration.
    let lowPowerModeMonitor: LowPowerModeMonitor
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
    let qualityMetricsStore: SuggestionQualityMetricsStore
    /// Per-day accepted word counts backing the menu-bar label and the Settings statistics.
    /// Owned here so the coordinator, menu bar, and Settings share one instance.
    let dailyCompletionStats: DailyCompletionStats
    let typingHistoryStore: TypingHistoryStore
    /// Encrypted on-device accept/reject learning (see `MemoryRecorder`). Owned here so settings
    /// and the termination flush share one instance with the suggestion coordinator.
    let memoryRecorder: MemoryRecorder
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
        let endpointCredentialStore = KeychainOpenAICompatibleCredentialStore()
        let suggestionSettings = SuggestionSettingsModel(
            configuration: configuration,
            endpointCredentialStore: endpointCredentialStore
        )
        let openAICompatibleClient = OpenAICompatibleAPIClient()
        let openAICompatibleConnectionModel = OpenAICompatibleConnectionModel(
            client: openAICompatibleClient
        )
        let foundationModelAvailabilityService = FoundationModelAvailabilityService()
        let powerSourceMonitor = PowerSourceMonitor()
        let lowPowerModeMonitor = LowPowerModeMonitor()
        let keyboardInputSourceMonitor = KeyboardInputSourceMonitor()
        let suppressionController = InputSuppressionController()
        let inputMonitor = InputMonitor(
            permissionProvider: { permissionManager.inputMonitoringGranted },
            suppressionController: suppressionController
        )
        let calendarAccessibilityCaptureGuard = CalendarAccessibilityCaptureGuard()
        inputMonitor.onPointerDown = { [weak calendarAccessibilityCaptureGuard] point in
            calendarAccessibilityCaptureGuard?.handlePointerDown(atAccessibilityPoint: point)
        }
        inputMonitor.globalToggleKeyCodeProvider = { suggestionSettings.globalToggleKeyCode }
        inputMonitor.globalToggleKeyModifiersProvider = { suggestionSettings.globalToggleKeyModifiers }
        inputMonitor.onGlobalToggleHotkey = { [weak suggestionSettings] in
            suggestionSettings?.toggleGloballyEnabled()
        }
        // Stop the deep AX walk when Ghostype is disabled for the focused app or while Calendar's
        // fragile date/time editor is active. The latter is interaction-scoped: Calendar text fields
        // still resolve normally, unlike the old app-wide suppression workaround for #544.
        let focusModel = FocusTrackingModel(
            permissionProvider: { permissionManager.accessibilityGranted },
            ignoredBundleIdentifier: Bundle.main.bundleIdentifier,
            // The Context pane's live-preview field is the single sanctioned spot where Ghostype may
            // complete inside its own UI; the focus tracker recognises it by this AX identifier.
            selfCaptureAllowedElementIdentifier: ContextLivePreview.accessibilityIdentifier,
            isCaptureSuppressedForBundle: { bundleIdentifier in
                guard suggestionSettings.isGloballyEnabled,
                      !suggestionSettings.isTemporarilyPaused
                else { return true }
                if let bundleIdentifier,
                   suggestionSettings.isApplicationDisabled(bundleIdentifier: bundleIdentifier) {
                    return true
                }
                return calendarAccessibilityCaptureGuard.shouldSuppressCapture(
                    for: bundleIdentifier
                )
            }
        )
        // The snapshot is poll-based, so after a fast app switch the closure may briefly
        // evaluate against the previous app's identity until the next AX poll fires. This
        // is the same race the downstream evaluator already has — not a new regression.
        inputMonitor.shouldProcessEventsProvider = { [weak focusModel] in
            guard suggestionSettings.isGloballyEnabled,
                  !suggestionSettings.isTemporarilyPaused
            else { return false }
            guard let snapshot = focusModel?.snapshot else { return true }
            if calendarAccessibilityCaptureGuard.shouldSuppressCapture(
                for: snapshot.bundleIdentifier
            ) {
                return false
            }
            // Terminals stay unobserved unless the caret is at a coding agent's prompt and the user
            // opted in; the agent's empty prompt is detected before its first keystroke arrives.
            if TerminalAppDetector.isTerminal(bundleIdentifier: snapshot.bundleIdentifier),
               !(suggestionSettings.completeInCodingAgents && snapshot.context?.isCodingAgentPrompt == true) {
                return false
            }
            if let bundleID = snapshot.bundleIdentifier,
               suggestionSettings.isApplicationDisabled(bundleIdentifier: bundleID) {
                return false
            }
            return true
        }
        // Resolve against the latest focus snapshot so each keystroke uses that app's binding.
        // The snapshot can briefly lag a fast switch, matching the evaluator race above.
        inputMonitor.acceptanceBindingProvider = { [weak focusModel] in
            let binding = suggestionSettings.resolvedAcceptBinding(
                forBundleIdentifier: focusModel?.snapshot.bundleIdentifier
            )
            return (binding.keyCode, binding.modifiers)
        }
        inputMonitor.fullAcceptanceBindingProvider = { [weak focusModel] in
            let binding = suggestionSettings.resolvedFullAcceptBinding(
                forBundleIdentifier: focusModel?.snapshot.bundleIdentifier
            )
            return (binding.keyCode, binding.modifiers)
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
        // Always-on quality counters (generated / shown / suppressed-by-reason / accepted).
        // Counters only, no content, so unlike latency tracking there is no opt-in gate.
        let qualityMetricsStore = SuggestionQualityMetricsStore()
        // Per-day accepted word counts for the menu-bar label and Settings statistics.
        // Counts only, no content, so like the quality counters there is no opt-in gate.
        let dailyCompletionStats = DailyCompletionStats()
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
        let overlayController = OverlayController(
            suggestionSettings: suggestionSettings,
            baselineCalibrator: HostBaselineCalibrator(),
            faceMemoryDefaults: .standard
        )
        let activationIndicatorController = ActivationIndicatorController()
        // While a suggestion is on screen the icon marks its line, which the overlay knows exactly.
        overlayController.onPresentedLineChange = { [weak activationIndicatorController, weak focusModel] line in
            activationIndicatorController?.followPresentedLine(line)
            focusModel?.setSuggestionVisible(line != nil)
        }
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

        let routedEngine: any SuggestionGenerating = SuggestionEngineRouter(
            suggestionSettings: suggestionSettings,
            foundationModelEngine: foundationModelEngine,
            llamaEngine: LlamaSuggestionEngine(runtimeManager: runtimeManager),
            performanceMetricsStore: performanceMetricsStore,
            qualityMetricsStore: qualityMetricsStore,
            llamaModelNameProvider: { [weak runtimeManager] in
                runtimeManager?.currentModelFilename
            },
            openAICompatibleEngine: OpenAICompatibleSuggestionEngine(
                client: openAICompatibleClient,
                configurationProvider: { [weak suggestionSettings] in
                    guard let suggestionSettings else {
                        throw OpenAICompatibleClientError.invalidResponse
                    }
                    return try suggestionSettings.openAICompatibleConfiguration
                },
                apiKeyProvider: { [weak suggestionSettings] in
                    try suggestionSettings?.openAICompatibleAPIKey()
                }
            ),
            endpointModelNameProvider: { [weak suggestionSettings] in
                suggestionSettings?.openAICompatibleModelName.nonEmpty
            }
        )
        // Under `-ghostype-debug` with `ghostypeDebugForcedSuggestion` set, every request answers with
        // that fixed text so ghost placement can be measured deterministically without a model.
        // Typing history owns its own encrypted archive. Inside the XCTest host it starts empty and
        // never opens the real archive or Keychain item, so tests cannot read or overwrite it.
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let typingHistoryStore = TypingHistoryStore(loadsArchive: !isTestHost)
        // Persistent suggestion memory: encrypted SQLite accept/reject learning that survives
        // restarts (issue #446). Like typing history, the test host never opens the real database
        // or Keychain item, so tests cannot read or overwrite the user's memory.
        let persistentMemoryStore = PersistentMemoryStore()
        let memoryRecorder = MemoryRecorder(store: persistentMemoryStore, loadsMemory: !isTestHost)
        let memoryContextProvider = MemoryContextProvider(
            store: persistentMemoryStore,
            isEnabled: { [weak memoryRecorder] in memoryRecorder?.isEnabled ?? false },
            strength: { [weak memoryRecorder] in memoryRecorder?.strength ?? .medium }
        )
        // After every persist batch (and the launch load), reload the cached vocabulary the prompt
        // builders read from, so prompts trail learning by at most the recorder's debounce window.
        // `refreshCurrent` re-reads the last-requested bundle plus the global aggregate.
        memoryRecorder.onDidPersist = { [weak memoryContextProvider] in
            Task { await memoryContextProvider?.refreshCurrent() }
        }
        // Typed-text learning: finished history recordings feed the user's own wording into
        // suggestion memory as `.typed` events. This is the cold-start fix — the vocabulary
        // learns from everything the user types, not just Tab-accepts. Secure fields never
        // reach the history recorder, so `isSecure` is always false here.
        typingHistoryStore.onDidFinishRecording = { [weak memoryRecorder] text, bundleId in
            memoryRecorder?.recordTyped(text, bundleIdentifier: bundleId, isSecure: false)
        }
        // Phrase shortcuts answer from history before the router runs. The live engine kind is
        // read per request so a power-source switch to the endpoint stops shortcuts immediately.
        let historyAwareEngine = TypingHistoryPhraseEngine(
            wrapping: routedEngine,
            history: typingHistoryStore,
            engineKind: { [weak suggestionSettings] in suggestionSettings?.selectedEngine ?? .openAICompatible }
        )
        // Personal n-gram: builds in the background from typing history, then answers
        // synchronously (<1ms) on each keystroke. The "fast" layer; the LLM is the "smart" layer.
        // This is what makes the stream feel instant like Cotypist — no inference wait.
        // A separate method so `init()` stays under SwiftLint's complexity cap of 10 —
        // the two `guard`s inside the detached task would otherwise count against it.
        Self.startBackgroundNGramBuild(typingHistoryStore: typingHistoryStore, phraseEngine: historyAwareEngine)
        let suggestionEngine: any SuggestionGenerating = DebugForcedSuggestionEngine.isConfigured()
            ? DebugForcedSuggestionEngine(wrapping: historyAwareEngine)
            : historyAwareEngine

        // Per-user emoji recents/frequency. Built before the settings coordinator so the
        // "Clear History" control can reach it, and before the picker which reads and writes it.
        let emojiUsageStore = EmojiUsageStore()

        let settingsCoordinator = SettingsCoordinator(
            appUpdateManager: appUpdateManager,
            permissionManager: permissionManager,
            permissionGuidanceController: permissionGuidanceController,
            suggestionSettings: suggestionSettings,
            openAICompatibleConnectionModel: openAICompatibleConnectionModel,
            foundationModelAvailabilityService: foundationModelAvailabilityService,
            runtimeModel: runtimeModel,
            modelDownloadManager: modelDownloadManager,
            huggingFaceSearchService: huggingFaceSearchService,
            performanceMetricsStore: performanceMetricsStore,
            qualityMetricsStore: qualityMetricsStore,
            dailyCompletionStats: dailyCompletionStats,
            systemMetricsStore: systemMetricsStore,
            onShowWelcome: { [weak welcomeCoordinator] in
                welcomeCoordinator?.showWelcome()
            },
            clearEmojiHistory: { emojiUsageStore.clear() },
            typingHistoryStore: typingHistoryStore,
            memoryRecorder: memoryRecorder
        )

        let interactionState = SuggestionInteractionState()
        let workController = SuggestionWorkController()
        // Constructed once at app scope so the underlying `NSSpellChecker` document tag survives
        // across coordinator state transitions instead of churning per keystroke.
        let spellChecker = CurrentWordSpellChecker()
        // No launch-time preload: a fully built index costs tens of MB resident for a feature that
        // is only consulted once the typo gate actually finds a misspelling, and the first
        // consultation triggers the same background build (`cachedIndexOrRequestLoad`) with the
        // designed NSSpellChecker fallback ranking corrections until it lands. The only cost of
        // staying cold is that the first correction or two after launch rank via the system
        // checker instead of corpus frequency.
        let symSpellCorrector = SymSpellCorrector(
            preloadLanguage: nil
        )
        let suggestionCoordinator = SuggestionCoordinator(
            permissionManager: permissionManager,
            lowPowerModeProvider: lowPowerModeMonitor,
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
            spellingLanguageResolver: SpellingLanguageResolver(),
            qualityMetricsStore: qualityMetricsStore,
            dailyCompletionStats: dailyCompletionStats,
            historyProvider: typingHistoryStore,
            memoryRecorder: memoryRecorder,
            memoryContext: memoryContextProvider
        )

        // The emoji picker is a sibling to the suggestion coordinator. It reuses the input monitor,
        // focus model, and inserter, but owns its own trigger state machine and floating panel.
        let emojiPickerController = EmojiPickerController(
            // Deferred: decoding and indexing the bundled emoji catalog costs a few MB of resident
            // strings that most sessions never use; the picker builds it on first `:` capture.
            matcherProvider: { EmojiMatcher(catalog: EmojiCatalog.bundled()) },
            panel: EmojiPickerPanelController(),
            focusModel: focusModel,
            inputMonitor: inputMonitor,
            inserter: suggestionInserter,
            isEnabled: { suggestionSettings.isEmojiPickerEnabled },
            emojiPreferences: { suggestionSettings.emojiVariantPreferences },
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
            acceptKeyLabel: {
                suggestionSettings.emojiPickerAcceptKeyLabel(
                    forBundleIdentifier: focusModel.snapshot.bundleIdentifier
                )
            },
            isWordAcceptKey: { inputMonitor.isWordAcceptKey($0) }
        )
        // Selected-word synonyms reuse the macro's single-row preview panel (a second instance, so
        // the two never fight over one window) and the same inserter. They ask `routedEngine`, the
        // engine the user selected, rather than `suggestionEngine`: the typing-history and debug
        // wrappers exist for continuations and would answer a synonym prompt with phrase guesses.
        // The gate is the suggestion coordinator's own availability check, so synonyms are off
        // wherever suggestions are off.
        let synonymController = SynonymController(
            panel: InlinePreviewPanelController(),
            focusModel: focusModel,
            inserter: suggestionInserter,
            engine: routedEngine,
            disabledReason: { [weak suggestionCoordinator] snapshot in
                suggestionCoordinator?.synonymDisabledReason(focusSnapshot: snapshot) ?? "Ghostype is not running."
            }
        )
        // One coordinator fans every keystroke out to the inline-command controllers and owns the
        // input monitor's single capture decider and interception flag, which the `:`, `/` and
        // synonym features share. It is given first look at every keystroke the suggestion
        // coordinator receives.
        let inlineCommandCoordinator = InlineCommandCoordinator(
            emoji: emojiPickerController,
            macro: macroController,
            synonyms: synonymController,
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
        self.calendarAccessibilityCaptureGuard = calendarAccessibilityCaptureGuard
        self.appUpdateManager = appUpdateManager
        self.permissionGuidanceController = permissionGuidanceController
        self.suggestionSettings = suggestionSettings
        self.openAICompatibleConnectionModel = openAICompatibleConnectionModel
        self.foundationModelAvailabilityService = foundationModelAvailabilityService
        self.powerSourceMonitor = powerSourceMonitor
        self.lowPowerModeMonitor = lowPowerModeMonitor
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
        self.qualityMetricsStore = qualityMetricsStore
        self.dailyCompletionStats = dailyCompletionStats
        self.typingHistoryStore = typingHistoryStore
        self.memoryRecorder = memoryRecorder
        self.settingsCoordinator = settingsCoordinator
        self.activationIndicatorController = activationIndicatorController
        self.focusDebugOverlayController = CotabbyDebugOptions.areOverlaysAvailable
            ? FocusDebugOverlayController()
            : nil

        // Recording reads every focus snapshot; the store ignores them unless recording is on and
        // the text changed. The same rule that decides whether Ghostype suggests (on, not paused,
        // app or site not disabled, not paused for Low Power Mode) decides where recording may
        // happen, so history is only collected where Ghostype is active. The store checks the
        // field's capability, secure fields, and terminals itself.
        focusModel.$snapshot
            .sink { [weak typingHistoryStore, weak suggestionSettings, weak permissionManager, weak lowPowerModeMonitor] snapshot in
                guard let typingHistoryStore, let suggestionSettings, let permissionManager, let lowPowerModeMonitor else { return }
                typingHistoryStore.observe(snapshot) {
                    let settings = suggestionSettings.snapshot
                    return SuggestionAvailabilityEvaluator.disabledReason(
                        globallyEnabled: settings.isGloballyEnabled,
                        temporarilyPaused: settings.isTemporarilyPaused,
                        isLowPowerModeActive: lowPowerModeMonitor.isLowPowerModeEnabled,
                        isLowPowerModeAutoDisableEnabled: settings.isLowPowerModeAutoDisableEnabled,
                        disabledAppBundleIdentifiers: settings.disabledAppBundleIdentifiers,
                        disabledDomains: PerDomainDisableSettings.disabledDomains(),
                        suggestInIntegratedTerminals: settings.suggestInIntegratedTerminals,
                        completeInCodingAgents: settings.completeInCodingAgents,
                        codeEditorDisabledBundleIdentifiers: settings.codeEditorDisabledBundleIdentifiers,
                        inputMonitoringGranted: permissionManager.inputMonitoringGranted,
                        focusSnapshot: snapshot,
                        checkCapability: false
                    ) == nil
                }
            }
            .store(in: &cancellables)

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
        observeOpenAICompatibleSelection()
    }

    /// Builds the personal n-gram engine from typing history on a background thread and
    /// installs it into the phrase engine once ready. Runs detached (`.utility`) so the
    /// launch path never blocks on it; the install hops back to the main actor because
    /// the engine is mutated from the suggestion pipeline there. Weak captures on both
    /// the store and the engine: if either is gone by the time the build finishes, the
    /// result is simply dropped. Static so it can be called from `init` before all
    /// stored properties are initialized; extracted to keep the initializer's
    /// complexity bounded.
    private static func startBackgroundNGramBuild(
        typingHistoryStore: TypingHistoryStore,
        phraseEngine: TypingHistoryPhraseEngine
    ) {
        Task.detached(priority: .utility) { [weak typingHistoryStore, weak phraseEngine] in
            guard let store = typingHistoryStore else { return }
            let texts = await store.allTypedTexts()
            guard !texts.isEmpty else { return }
            let ngram = PersonalNGramEngine.build(from: texts)
            await MainActor.run { [weak phraseEngine] in
                phraseEngine?.ngramEngine = ngram
            }
        }
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
            suggestionSettings.$batteryEndpointModelName.map { _ in () }.eraseToAnyPublisher(),
            suggestionSettings.$pluggedInEngine.map { _ in () }.eraseToAnyPublisher(),
            suggestionSettings.$pluggedInModelFilename.map { _ in () }.eraseToAnyPublisher(),
            suggestionSettings.$pluggedInEndpointModelName.map { _ in () }.eraseToAnyPublisher(),
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
        case .openAICompatible(let modelName):
            guard !modelName.isEmpty else { return }
            suggestionSettings.setOpenAICompatibleModelName(modelName)
            suggestionSettings.selectEngine(.openAICompatible)
        }
    }

    /// Connect once when the endpoint engine becomes active. Only server identity and credentials
    /// invalidate discovery: the selected model and generation route do not affect `GET /models`,
    /// so changing either must keep the catalog and connected status alive. Settings still owns
    /// explicit Connect/Return refreshes and avoids network traffic per keystroke.
    private func observeOpenAICompatibleSelection() {
        suggestionSettings.$selectedEngine
            .removeDuplicates()
            .sink { [weak self] engine in
                guard engine == .openAICompatible, let self else { return }
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        let configuration = try self.suggestionSettings.openAICompatibleConfiguration
                        let apiKey = try self.suggestionSettings.openAICompatibleAPIKey()
                        await self.openAICompatibleConnectionModel.refresh(
                            configuration: configuration,
                            apiKey: apiKey
                        )
                    } catch {
                        self.openAICompatibleConnectionModel.invalidate()
                    }
                }
            }
            .store(in: &cancellables)

        let configurationChanges: [AnyPublisher<Void, Never>] = [
            suggestionSettings.$openAICompatibleBaseURL.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            suggestionSettings.$endpointCredentialRevision.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ]

        Publishers.MergeMany(configurationChanges)
            .sink { [weak self] _ in
                guard let self, self.suggestionSettings.selectedEngine == .openAICompatible else { return }
                self.openAICompatibleConnectionModel.invalidate()
            }
            .store(in: &cancellables)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
