import AppKit
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
    /// Effective suggestion focus after arbitration between AX, shell-hook, and verified TUI data.
    let terminalAwareFocusModel: TerminalAwareFocusModel
    let terminalIntegrationService: TerminalIntegrationService
    let shellPromptGeometryCoordinator: ShellPromptGeometryCoordinator
    let tuiContextCoordinator: TuiContextCoordinator
    let inputMonitor: InputMonitor
    /// Temporarily pauses Calendar AX traversal only while its date/time editor is active.
    let calendarAccessibilityCaptureGuard: CalendarAccessibilityCaptureGuard
    let appUpdateManager: AppUpdateManager
    let permissionGuidanceController: PermissionGuidanceController
    let suggestionSettings: SuggestionSettingsModel
    let openAICompatibleConnectionModel: OpenAICompatibleConnectionModel
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
    let qualityMetricsStore: SuggestionQualityMetricsStore
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
        inputMonitor.acceptanceKeyCodeProvider = { suggestionSettings.acceptanceKeyCode }
        inputMonitor.acceptanceKeyModifiersProvider = { suggestionSettings.acceptanceKeyModifiers }
        inputMonitor.fullAcceptanceKeyCodeProvider = { suggestionSettings.fullAcceptanceKeyCode }
        inputMonitor.fullAcceptanceKeyModifiersProvider = { suggestionSettings.fullAcceptanceKeyModifiers }
        inputMonitor.globalToggleKeyCodeProvider = { suggestionSettings.globalToggleKeyCode }
        inputMonitor.globalToggleKeyModifiersProvider = { suggestionSettings.globalToggleKeyModifiers }
        inputMonitor.onGlobalToggleHotkey = { [weak suggestionSettings] in
            suggestionSettings?.toggleGloballyEnabled()
        }
        // Stop the deep AX walk when Cotabby is disabled for the focused app or while Calendar's
        // fragile date/time editor is active. The latter is interaction-scoped: Calendar text fields
        // still resolve normally, unlike the old app-wide suppression workaround for #544.
        let focusModel = FocusTrackingModel(
            permissionProvider: { permissionManager.accessibilityGranted },
            ignoredBundleIdentifier: Bundle.main.bundleIdentifier,
            // The Context pane's live-preview field is the single sanctioned spot where Cotabby may
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
            },
            publishesPollingEvents: FocusDebugOverlayController.isEnabled
        )
        let terminalAwareFocusModel = TerminalAwareFocusModel(accessibilityModel: focusModel)
        let terminalIntegrationService = TerminalIntegrationService()
        // The snapshot is poll-based, so after a fast app switch the closure may briefly
        // evaluate against the previous app's identity until the next AX poll fires. This
        // is the same race the downstream evaluator already has — not a new regression.
        inputMonitor.shouldProcessEventsProvider = { [weak focusModel] in
            Self.shouldProcessInputEvents(
                snapshot: focusModel?.snapshot,
                settings: suggestionSettings,
                calendarGuard: calendarAccessibilityCaptureGuard
            )
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
        let terminalSubsystem = Self.makeTerminalSubsystem(
            focusModel: focusModel,
            effectiveFocusModel: terminalAwareFocusModel,
            integrationService: terminalIntegrationService,
            settings: suggestionSettings,
            permissions: permissionManager
        )
        let shellPromptGeometryCoordinator = terminalSubsystem.shellGeometry
        let tuiContextCoordinator = terminalSubsystem.tuiContext
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
            focusModel: terminalAwareFocusModel,
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
            qualityMetricsStore: qualityMetricsStore
        )

        Self.wireTerminalSubsystem(TerminalWiring(
            suggestionCoordinator: suggestionCoordinator,
            focusModel: terminalAwareFocusModel,
            integrationService: terminalIntegrationService,
            shellGeometry: shellPromptGeometryCoordinator,
            tuiContext: tuiContextCoordinator,
            settings: suggestionSettings,
            permissions: permissionManager
        ))

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
        self.terminalAwareFocusModel = terminalAwareFocusModel
        self.terminalIntegrationService = terminalIntegrationService
        self.shellPromptGeometryCoordinator = shellPromptGeometryCoordinator
        self.tuiContextCoordinator = tuiContextCoordinator
        self.inputMonitor = inputMonitor
        self.calendarAccessibilityCaptureGuard = calendarAccessibilityCaptureGuard
        self.appUpdateManager = appUpdateManager
        self.permissionGuidanceController = permissionGuidanceController
        self.suggestionSettings = suggestionSettings
        self.openAICompatibleConnectionModel = openAICompatibleConnectionModel
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
        self.qualityMetricsStore = qualityMetricsStore
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
        observeOpenAICompatibleSelection()
    }

    private static func shouldProcessInputEvents(
        snapshot: FocusSnapshot?,
        settings: SuggestionSettingsModel,
        calendarGuard: CalendarAccessibilityCaptureGuard
    ) -> Bool {
        guard settings.isGloballyEnabled, !settings.isTemporarilyPaused else { return false }
        guard let snapshot else { return true }
        guard !calendarGuard.shouldSuppressCapture(for: snapshot.bundleIdentifier) else {
            return false
        }
        if TerminalAppDetector.isTerminal(bundleIdentifier: snapshot.bundleIdentifier)
            || snapshot.context?.isIntegratedTerminal == true {
            // Input must reach the TUI observer before verified OCR owns focus. The suggestion
            // evaluator remains fail-closed until an authoritative terminal role arrives.
            return settings.suggestInIntegratedTerminals
        }
        if let bundleIdentifier = snapshot.bundleIdentifier,
           settings.isApplicationDisabled(bundleIdentifier: bundleIdentifier) {
            return false
        }
        return true
    }

    /// Builds the screen-aware half of terminal support. IPC remains a separate long-lived service
    /// because it starts and stops with the user's opt-in from `AppDelegate`.
    private static func makeTerminalSubsystem(
        focusModel: FocusTrackingModel,
        effectiveFocusModel: TerminalAwareFocusModel,
        integrationService: TerminalIntegrationService,
        settings: SuggestionSettingsModel,
        permissions: PermissionManager
    ) -> TerminalSubsystem {
        let screenshots = TerminalWindowScreenshotService()
        let shellGeometry = ShellPromptGeometryCoordinator(
            extractor: ScreenTextExtractor(),
            captureProvider: { snapshot, pid in
                let app = NSRunningApplication(processIdentifier: pid_t(pid))
                return try await screenshots.capture(
                    pid: pid,
                    bundleIdentifier: snapshot.terminalBundleIdentifier,
                    applicationName: app?.localizedName ?? snapshot.terminalBundleIdentifier,
                    preferredRegion: preferredTerminalRegion(
                        bundleIdentifier: snapshot.terminalBundleIdentifier,
                        pid: pid,
                        focusModel: focusModel
                    )
                )
            },
            latestSnapshotProvider: { [weak integrationService] in
                integrationService?.latestSnapshot(for: $0)
            },
            isEnabled: {
                settings.suggestInIntegratedTerminals && permissions.screenRecordingGranted
            }
        )
        let tuiContext = TuiContextCoordinator(
            reader: TuiContextReader(extractor: ScreenTextExtractor()),
            candidateProvider: { currentTuiCandidate(focusModel: focusModel) },
            captureProvider: { candidate in
                try await screenshots.capture(
                    pid: candidate.pid,
                    bundleIdentifier: candidate.bundleIdentifier,
                    applicationName: candidate.applicationName,
                    preferredRegion: candidate.preferredCaptureRegion
                )
            },
            foregroundProcessProvider: { candidate in
                let roots = [candidate.pid] + integrationService.activeShellPIDs(
                    forBundleIdentifier: candidate.bundleIdentifier
                )
                return ProcessTreeInspector.subtreeProcessNames(
                    rootedAt: Array(Set(roots)),
                    includingRoots: true
                )
            },
            isEnabled: {
                settings.suggestInIntegratedTerminals && permissions.screenRecordingGranted
            },
            isShellActivelyReporting: {
                integrationService.isRecentlyReporting(forBundleIdentifier: $0)
            },
            injectSnapshot: { effectiveFocusModel.publishTerminalContext($0) },
            clearInjection: {
                effectiveFocusModel.clearTerminalContext(
                    ifRole: TerminalInputRole.claudeCodeTUI.rawValue
                )
            }
        )
        return TerminalSubsystem(shellGeometry: shellGeometry, tuiContext: tuiContext)
    }

    private static func preferredTerminalRegion(
        bundleIdentifier: String,
        pid: Int32,
        focusModel: FocusTrackingModel
    ) -> CGRect? {
        guard TerminalAppDetector.hostsEmbeddedTerminal(bundleIdentifier: bundleIdentifier),
              let context = focusModel.snapshot.context,
              context.bundleIdentifier == bundleIdentifier,
              context.processIdentifier == pid,
              context.isIntegratedTerminal,
              let appKitFrame = context.inputFrameRect,
              !appKitFrame.isEmpty else { return nil }
        // Display-coordinate conversion is a Y-axis flip and therefore its own inverse.
        return AXHelper.cocoaRect(fromAccessibilityRect: appKitFrame)
    }

    private static func currentTuiCandidate(
        focusModel: FocusTrackingModel
    ) -> TuiContextCoordinator.Candidate? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = app.bundleIdentifier,
              TerminalAppDetector.isTerminalHost(bundleIdentifier: bundleIdentifier)
        else { return nil }
        if TerminalAppDetector.hostsEmbeddedTerminal(bundleIdentifier: bundleIdentifier),
           focusModel.snapshot.context?.isIntegratedTerminal != true {
            return nil
        }
        let pid = Int32(app.processIdentifier)
        return TuiContextCoordinator.Candidate(
            bundleIdentifier: bundleIdentifier,
            applicationName: app.localizedName ?? bundleIdentifier,
            pid: pid,
            title: TerminalGeometryResolver.windowTitle(forPid: app.processIdentifier),
            preferredCaptureRegion: preferredTerminalRegion(
                bundleIdentifier: bundleIdentifier,
                pid: pid,
                focusModel: focusModel
            )
        )
    }

    private static func wireTerminalSubsystem(_ wiring: TerminalWiring) {
        let focusModel = wiring.focusModel
        let shellGeometry = wiring.shellGeometry
        let settings = wiring.settings
        let permissions = wiring.permissions
        let integrationService = wiring.integrationService
        let suggestionCoordinator = wiring.suggestionCoordinator
        let tuiContext = wiring.tuiContext

        integrationService.onSnapshotUpdate = {
            handleShellSnapshot(
                $0,
                focusModel: focusModel,
                shellGeometry: shellGeometry,
                settings: settings,
                permissions: permissions
            )
        }
        shellGeometry.onGeometryResolved = {
            handleResolvedShellGeometry(
                $0,
                focusModel: focusModel,
                settings: settings
            )
        }
        integrationService.onSessionChange = { [weak integrationService] in
            guard let integrationService else { return }
            // Session identities include nonces and are never reused. Clearing the small anchor
            // cache on lifecycle changes prevents closed tabs from accumulating indefinitely;
            // active shells re-anchor on their next buffer report.
            shellGeometry.invalidateAll()
            handleTerminalSessionChange(
                focusModel: focusModel,
                service: integrationService
            )
        }
        suggestionCoordinator.onTerminalInsertion = { [weak integrationService] context, text in
            guard let integrationService else { return }
            handleTerminalInsertion(
                context,
                insertedText: text,
                service: integrationService
            )
        }
        suggestionCoordinator.onTerminalReplacement = { [weak integrationService] context, text in
            guard let integrationService else { return }
            handleTerminalReplacement(
                context,
                replacementText: text,
                service: integrationService
            )
        }
        suggestionCoordinator.terminalIntegrationActiveProvider = { [weak focusModel] in
            focusModel?.snapshot.context?.terminalInputRole != nil
        }
        suggestionCoordinator.tuiInputObserver = { [weak tuiContext] _ in tuiContext?.observeInput() }
    }

    private static func handleShellSnapshot(
        _ snapshot: TerminalFocusSnapshot,
        focusModel: TerminalAwareFocusModel,
        shellGeometry: ShellPromptGeometryCoordinator,
        settings: SuggestionSettingsModel,
        permissions: PermissionManager
    ) {
        guard settings.suggestInIntegratedTerminals,
              permissions.screenRecordingGranted,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == snapshot.terminalBundleIdentifier,
              let pid = TerminalGeometryResolver.terminalAppPid(
                  forBundleIdentifier: snapshot.terminalBundleIdentifier
              )
        else { return }
        if let resolved = shellGeometry.resolve(snapshot, terminalPID: pid) {
            focusModel.publishTerminalContext(TerminalFocusAdapter.adapt(resolved, terminalPid: pid))
        }
    }

    private static func handleResolvedShellGeometry(
        _ snapshot: TerminalFocusSnapshot,
        focusModel: TerminalAwareFocusModel,
        settings: SuggestionSettingsModel
    ) {
        guard settings.suggestInIntegratedTerminals,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == snapshot.terminalBundleIdentifier,
              let pid = TerminalGeometryResolver.terminalAppPid(
                  forBundleIdentifier: snapshot.terminalBundleIdentifier
              ) else { return }
        focusModel.publishTerminalContext(TerminalFocusAdapter.adapt(snapshot, terminalPid: pid))
    }

    private static func handleTerminalSessionChange(
        focusModel: TerminalAwareFocusModel,
        service: TerminalIntegrationService
    ) {
        guard let context = focusModel.snapshot.context,
              context.terminalInputRole == .shell,
              service.identity(forElementIdentifier: context.elementIdentifier) == nil
        else { return }
        focusModel.clearTerminalContext(ifRole: TerminalInputRole.shell.rawValue)
    }

    private static func handleTerminalInsertion(
        _ context: FocusedInputContext,
        insertedText: String,
        service: TerminalIntegrationService
    ) {
        guard context.terminalInputRole == .shell,
              let identity = service.identity(forElementIdentifier: context.elementIdentifier)
        else { return }
        service.applyOptimisticInsertion(identity: identity, insertedText: insertedText)
    }

    private static func handleTerminalReplacement(
        _ context: FocusedInputContext,
        replacementText: String,
        service: TerminalIntegrationService
    ) {
        guard context.terminalInputRole == .shell,
              let identity = service.identity(forElementIdentifier: context.elementIdentifier)
        else { return }
        service.applyOptimisticReplacement(identity: identity, replacementText: replacementText)
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

/// Pair returned by the terminal composition helper. Both coordinators live for the app lifetime;
/// their individual start/stop behavior remains owned by `AppDelegate`.
private struct TerminalSubsystem {
    let shellGeometry: ShellPromptGeometryCoordinator
    let tuiContext: TuiContextCoordinator
}

/// References needed to connect terminal source events after the suggestion coordinator exists.
private struct TerminalWiring {
    let suggestionCoordinator: SuggestionCoordinator
    let focusModel: TerminalAwareFocusModel
    let integrationService: TerminalIntegrationService
    let shellGeometry: ShellPromptGeometryCoordinator
    let tuiContext: TuiContextCoordinator
    let settings: SuggestionSettingsModel
    let permissions: PermissionManager
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
