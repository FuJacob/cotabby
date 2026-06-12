import Combine
import Foundation
import XCTest
@testable import Cotabby

/// Tests the coordinator-level acceptance contract.
///
/// `InputMonitor` owns the physical key event, but `SuggestionCoordinator` remains the final
/// validator for whether visible ghost text can be committed. These tests keep that boundary
/// explicit so future state-machine edits do not accidentally reintroduce `.ready` as a hard gate.
final class SuggestionCoordinatorAcceptanceTests: XCTestCase {
    private static var retainedCoordinators: [SuggestionCoordinator] = []

    override func tearDown() {
        runOnMainActor {
            Self.retainedCoordinators.removeAll()
        }
        super.tearDown()
    }

    func test_acceptCurrentSuggestionAllowsVisibleSessionWhileDebugStateIsDebouncing() {
        let coordinator: SuggestionCoordinator = runOnMainActor {
            let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")
            let context = FocusedInputContext(snapshot: snapshot, generation: 7)
            let interactionState = SuggestionInteractionState()
            let session = interactionState.startSession(
                fullText: " world again",
                liveContext: context,
                latency: 0.1
            )
            let overlayState = OverlayState.visible(
                text: session.remainingText,
                geometry: CotabbyTestFixtures.overlayGeometry(caretRect: context.caretRect),
                mode: .inline
            )
            let inputMonitor = StubSuggestionInputMonitor()
            let inserter = StubSuggestionInserter()
            let coordinator = makeCoordinator(
                snapshot: snapshot,
                overlayState: overlayState,
                inputMonitor: inputMonitor,
                inserter: inserter,
                interactionState: interactionState
            )
            coordinator.state = .debouncing

            XCTAssertTrue(
                inputMonitor.shouldConsumeAcceptKeyProvider(),
                "Preflight should depend on visible overlay, not `.ready`."
            )
            XCTAssertTrue(coordinator.acceptCurrentSuggestion())

            XCTAssertEqual(inserter.insertedChunks, [" world"])
            if case let .ready(remainingText, _) = coordinator.state {
                XCTAssertEqual(remainingText, " again")
            } else {
                XCTFail("Partial acceptance should leave the remaining suggestion ready.")
            }
            return coordinator
        }

        // Acceptance bookkeeping (diagnostics publishes, counters, stage logs) lands one runloop
        // hop after the gating tap callback returns (`deferAcceptanceBookkeeping`); drain that hop
        // before asserting on it. The session math and overlay state above are still synchronous.
        let bookkeepingDrained = expectation(description: "acceptance bookkeeping hop")
        DispatchQueue.main.async { bookkeepingDrained.fulfill() }
        wait(for: [bookkeepingDrained], timeout: 1.0)

        runOnMainActor {
            XCTAssertEqual(coordinator.latestAcceptanceAction, "Accepted next chunk with Tab.")
        }
    }

    func test_acceptCurrentSuggestion_withAddSpaceAfterAccept_insertsTrailingSpaceOnNonFinalWord() {
        // Full coordinator path with the setting ON and a multi-word suggestion: accepting the first
        // word must insert the word plus the suggestion's own following space (so the toggle fires
        // per word, not only when the suggestion is exhausted), while the tail keeps the rest.
        runOnMainActor {
            let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")
            let context = FocusedInputContext(snapshot: snapshot, generation: 7)
            let interactionState = SuggestionInteractionState()
            let session = interactionState.startSession(
                fullText: " world how",
                liveContext: context,
                latency: 0.1
            )
            let overlayState = OverlayState.visible(
                text: session.remainingText,
                geometry: CotabbyTestFixtures.overlayGeometry(caretRect: context.caretRect),
                mode: .inline
            )
            let inserter = StubSuggestionInserter()
            let coordinator = makeCoordinator(
                snapshot: snapshot,
                overlayState: overlayState,
                inputMonitor: StubSuggestionInputMonitor(),
                inserter: inserter,
                interactionState: interactionState,
                settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(addSpaceAfterAccept: true)
            )
            coordinator.state = .debouncing

            XCTAssertTrue(coordinator.acceptCurrentSuggestion())

            // " world" plus the model's own following space, consumed in one accept.
            XCTAssertEqual(inserter.insertedChunks, [" world "])
            if case let .ready(remainingText, _) = coordinator.state {
                XCTAssertEqual(remainingText, "how", "The consumed following space should not lead the tail.")
            } else {
                XCTFail("Partial acceptance should leave the remaining suggestion ready.")
            }
            Self.retainedCoordinators.append(coordinator)
        }
    }

    func test_acceptCurrentSuggestion_withoutAddSpaceAfterAccept_insertsWordWithoutTrailingSpace() {
        // Same setup with the setting OFF: byte-for-byte the prior behavior (no trailing space, the
        // following space leads the next chunk).
        runOnMainActor {
            let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")
            let context = FocusedInputContext(snapshot: snapshot, generation: 7)
            let interactionState = SuggestionInteractionState()
            let session = interactionState.startSession(
                fullText: " world how",
                liveContext: context,
                latency: 0.1
            )
            let overlayState = OverlayState.visible(
                text: session.remainingText,
                geometry: CotabbyTestFixtures.overlayGeometry(caretRect: context.caretRect),
                mode: .inline
            )
            let inserter = StubSuggestionInserter()
            let coordinator = makeCoordinator(
                snapshot: snapshot,
                overlayState: overlayState,
                inputMonitor: StubSuggestionInputMonitor(),
                inserter: inserter,
                interactionState: interactionState,
                settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(addSpaceAfterAccept: false)
            )
            coordinator.state = .debouncing

            XCTAssertTrue(coordinator.acceptCurrentSuggestion())

            XCTAssertEqual(inserter.insertedChunks, [" world"])
            if case let .ready(remainingText, _) = coordinator.state {
                XCTAssertEqual(remainingText, " how")
            } else {
                XCTFail("Partial acceptance should leave the remaining suggestion ready.")
            }
            Self.retainedCoordinators.append(coordinator)
        }
    }

    func test_acceptCurrentSuggestionCleansVisibleOverlayWhenSessionDisappears() {
        runOnMainActor {
            let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")
            let context = FocusedInputContext(snapshot: snapshot, generation: 7)
            let overlayState = OverlayState.visible(
                text: " stale",
                geometry: CotabbyTestFixtures.overlayGeometry(caretRect: context.caretRect),
                mode: .inline
            )
            let inputMonitor = StubSuggestionInputMonitor()
            let inserter = StubSuggestionInserter()
            let coordinator = makeCoordinator(
                snapshot: snapshot,
                overlayState: overlayState,
                inputMonitor: inputMonitor,
                inserter: inserter,
                interactionState: SuggestionInteractionState()
            )
            coordinator.state = .debouncing

            XCTAssertTrue(
                inputMonitor.shouldConsumeAcceptKeyProvider(),
                "A visible stale overlay should still route the accept key into the coordinator for cleanup."
            )
            XCTAssertFalse(coordinator.acceptCurrentSuggestion())

            XCTAssertTrue(inserter.insertedChunks.isEmpty)
            XCTAssertFalse(coordinator.overlayState.isVisible)
            XCTAssertEqual(coordinator.state, .idle)
        }
    }

    func test_acceptingFinalChunkDefersRegenerationAndRecordsAcceptedTail() {
        runOnMainActor {
            let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "what's on your mind")
            let context = FocusedInputContext(snapshot: snapshot, generation: 7)
            let interactionState = SuggestionInteractionState()
            let session = interactionState.startSession(
                fullText: " today",
                liveContext: context,
                latency: 0.1
            )
            let overlayState = OverlayState.visible(
                text: session.remainingText,
                geometry: CotabbyTestFixtures.overlayGeometry(caretRect: context.caretRect),
                mode: .inline
            )
            let inputMonitor = StubSuggestionInputMonitor()
            let inserter = StubSuggestionInserter()
            let coordinator = makeCoordinator(
                snapshot: snapshot,
                overlayState: overlayState,
                inputMonitor: inputMonitor,
                inserter: inserter,
                interactionState: interactionState
            )

            XCTAssertTrue(coordinator.acceptCurrentSuggestion())

            XCTAssertEqual(inserter.insertedChunks, [" today"])
            // The final-chunk accept starts the continuation immediately against the text the host
            // is about to publish (speculative prefetch) instead of idling through the publish
            // poll; the overlay still hides until that result lands and validates.
            XCTAssertEqual(coordinator.state, .generating)
            XCTAssertNotNil(coordinator.pendingSpeculativeSignature)
            XCTAssertFalse(coordinator.overlayState.isVisible)
            // It records what it committed so `apply` can drop a stale echo of the same tail.
            XCTAssertEqual(
                coordinator.lastAcceptedTail,
                AcceptedSuggestionTail(text: " today", precedingText: "what's on your mind")
            )
        }
    }

    func test_rapidSecondAcceptDuringRegenerationIsConsumedNotPassedThrough() {
        runOnMainActor {
            let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "what's on your mind")
            let context = FocusedInputContext(snapshot: snapshot, generation: 7)
            let interactionState = SuggestionInteractionState()
            _ = interactionState.startSession(
                fullText: " today",
                liveContext: context,
                latency: 0.1
            )
            let overlayState = OverlayState.visible(
                text: " today",
                geometry: CotabbyTestFixtures.overlayGeometry(caretRect: context.caretRect),
                mode: .inline
            )
            let inputMonitor = StubSuggestionInputMonitor()
            let inserter = StubSuggestionInserter()
            let coordinator = makeCoordinator(
                snapshot: snapshot,
                overlayState: overlayState,
                inputMonitor: inputMonitor,
                inserter: inserter,
                interactionState: interactionState
            )

            // First Tab accepts the only remaining chunk, exhausts the session, and arms the window.
            XCTAssertTrue(coordinator.acceptCurrentSuggestion())
            XCTAssertEqual(inserter.insertedChunks, [" today"])
            XCTAssertTrue(coordinator.isPostExhaustionAcceptanceArmed)
            XCTAssertFalse(coordinator.overlayState.isVisible)
            // Ownership of Tab was re-asserted even though the overlay is now hidden.
            XCTAssertEqual(inputMonitor.acceptInterceptionRequests.last, true)
            XCTAssertTrue(
                inputMonitor.shouldConsumeAcceptKeyProvider(),
                "The accept tap must keep owning Tab while the continuation regenerates."
            )

            // The rapid second Tab lands before the continuation regenerates. It must be swallowed
            // (consumed) and queued — never forwarded to the host as a real Tab that moves focus.
            XCTAssertTrue(
                coordinator.acceptCurrentSuggestion(),
                "A fast follow-up Tab during regeneration must be consumed, not passed through to the host."
            )
            XCTAssertEqual(
                inserter.insertedChunks,
                [" today"],
                "The second Tab has nothing to insert yet; it is queued, not inserted."
            )
            XCTAssertTrue(coordinator.hasQueuedPostExhaustionAccept)
        }
    }

    func test_postExhaustionWindowReleasesAcceptKeyWhenOverlayHides() {
        runOnMainActor {
            let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "what's on your mind")
            let context = FocusedInputContext(snapshot: snapshot, generation: 7)
            let interactionState = SuggestionInteractionState()
            _ = interactionState.startSession(
                fullText: " today",
                liveContext: context,
                latency: 0.1
            )
            let overlayState = OverlayState.visible(
                text: " today",
                geometry: CotabbyTestFixtures.overlayGeometry(caretRect: context.caretRect),
                mode: .inline
            )
            let inputMonitor = StubSuggestionInputMonitor()
            let inserter = StubSuggestionInserter()
            let coordinator = makeCoordinator(
                snapshot: snapshot,
                overlayState: overlayState,
                inputMonitor: inputMonitor,
                inserter: inserter,
                interactionState: interactionState
            )

            XCTAssertTrue(coordinator.acceptCurrentSuggestion())
            XCTAssertTrue(coordinator.isPostExhaustionAcceptanceArmed)

            // Any teardown that hides the overlay (focus change, typing, dismissal, an empty
            // regeneration) must end the window so the user can Tab out of the field normally again.
            coordinator.invalidateActiveSuggestion(reason: "Focus moved to another field.")

            XCTAssertFalse(coordinator.isPostExhaustionAcceptanceArmed)
            XCTAssertFalse(coordinator.hasQueuedPostExhaustionAccept)
            XCTAssertFalse(
                inputMonitor.shouldConsumeAcceptKeyProvider(),
                "Once the window is released the accept tap should stop owning Tab."
            )
            XCTAssertFalse(
                coordinator.acceptCurrentSuggestion(),
                "With the window released and no suggestion, Tab must pass through to the host."
            )
        }
    }

    func test_queuedPostExhaustionAcceptInsertsNextWordWhenContinuationArrives() {
        runOnMainActor {
            let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")
            let context = FocusedInputContext(snapshot: snapshot, generation: 7)
            let interactionState = SuggestionInteractionState()
            let session = interactionState.startSession(
                fullText: " world again",
                liveContext: context,
                latency: 0.1
            )
            let overlayState = OverlayState.visible(
                text: session.remainingText,
                geometry: CotabbyTestFixtures.overlayGeometry(caretRect: context.caretRect),
                mode: .inline
            )
            let inputMonitor = StubSuggestionInputMonitor()
            let inserter = StubSuggestionInserter()
            let coordinator = makeCoordinator(
                snapshot: snapshot,
                overlayState: overlayState,
                inputMonitor: inputMonitor,
                inserter: inserter,
                interactionState: interactionState
            )
            // Simulate a Tab that was swallowed and queued while this continuation was still loading;
            // `apply` calls `flushQueuedPostExhaustionAcceptIfNeeded` once the suggestion is on screen.
            coordinator.isPostExhaustionAcceptanceArmed = true
            coordinator.hasQueuedPostExhaustionAccept = true

            coordinator.flushQueuedPostExhaustionAcceptIfNeeded()

            XCTAssertEqual(
                inserter.insertedChunks,
                [" world"],
                "The queued Tab should accept the continuation's first word."
            )
            XCTAssertFalse(coordinator.isPostExhaustionAcceptanceArmed)
            XCTAssertFalse(coordinator.hasQueuedPostExhaustionAccept)
        }
    }

    /// A cached suggestion consistent with the live text must re-show without any engine call.
    /// The stub engine throws on every generation, so reaching `.ready` proves the restore path
    /// satisfied the prediction cycle on its own.
    @MainActor
    func test_anchorCacheRestoresSuggestionWithoutGenerating() async {
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello wo")
        let interactionState = SuggestionInteractionState()
        let coordinator = makeCoordinator(
            snapshot: snapshot,
            overlayState: .hidden(reason: "test"),
            inputMonitor: StubSuggestionInputMonitor(),
            inserter: StubSuggestionInserter(),
            interactionState: interactionState
        )
        let identityKey = FocusedInputContext(snapshot: snapshot, generation: 1).focusedInputIdentityKey
        // The suggestion was generated when the field held "Hello"; the user has since typed
        // " wo", which is exactly the suggestion's first three characters.
        coordinator.suggestionAnchorCache.record(
            identityKey: identityKey,
            precedingText: "Hello",
            fullText: " world again"
        )

        await coordinator.generateFromCurrentFocus(workID: coordinator.currentWorkID)

        guard case let .ready(text, latency) = coordinator.state else {
            XCTFail("Expected a restored suggestion, got \(coordinator.state)")
            return
        }
        XCTAssertEqual(text, "rld again")
        XCTAssertEqual(latency, 0)
        XCTAssertEqual(interactionState.activeSession?.fullText, "rld again")
    }

    /// A speculative post-acceptance result carries a generation older than the live one by
    /// construction; it must still apply when the live content matches the signature it was
    /// built against, and must consume the exemption.
    @MainActor
    func test_applyAcceptsSpeculativeResultWhenContentSignatureMatches() async {
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello world ")
        let interactionState = SuggestionInteractionState()
        let coordinator = makeCoordinator(
            snapshot: snapshot,
            overlayState: .hidden(reason: "test"),
            inputMonitor: StubSuggestionInputMonitor(),
            inserter: StubSuggestionInserter(),
            interactionState: interactionState
        )
        coordinator.pendingSpeculativeSignature =
            FocusedInputContext(snapshot: snapshot, generation: 1).contentSignature
        let speculativeResult = SuggestionResult(
            generation: 999,
            rawText: "from here on",
            text: "from here on",
            latency: 0.1
        )

        await coordinator.apply(result: speculativeResult, workID: coordinator.currentWorkID)

        guard case let .ready(text, _) = coordinator.state else {
            XCTFail("Expected the speculative result to apply, got \(coordinator.state)")
            return
        }
        XCTAssertEqual(text, "from here on")
        XCTAssertNil(coordinator.pendingSpeculativeSignature, "the exemption is single-use")
    }

    /// Without the signature exemption, a stale-generation result must keep being dropped.
    @MainActor
    func test_applyStillDropsStaleResultsWithoutSpeculativeSignature() async {
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello world ")
        let coordinator = makeCoordinator(
            snapshot: snapshot,
            overlayState: .hidden(reason: "test"),
            inputMonitor: StubSuggestionInputMonitor(),
            inserter: StubSuggestionInserter(),
            interactionState: SuggestionInteractionState()
        )
        let staleResult = SuggestionResult(
            generation: 999,
            rawText: "from here on",
            text: "from here on",
            latency: 0.1
        )

        await coordinator.apply(result: staleResult, workID: coordinator.currentWorkID)

        if case .ready = coordinator.state {
            XCTFail("A stale result with no speculative exemption must not apply")
        }
    }

    @MainActor
    private func makeCoordinator(
        snapshot: FocusedInputSnapshot,
        overlayState: OverlayState,
        inputMonitor: StubSuggestionInputMonitor,
        inserter: StubSuggestionInserter,
        interactionState: SuggestionInteractionState,
        settingsSnapshot: SuggestionSettingsSnapshot = CotabbyTestFixtures.settingsSnapshot()
    ) -> SuggestionCoordinator {
        let focusSnapshot = FocusSnapshot(
            applicationName: snapshot.applicationName,
            bundleIdentifier: snapshot.bundleIdentifier,
            capability: .supported,
            context: snapshot,
            inspection: nil
        )
        let settingsProvider = StubSuggestionSettingsProvider()
        settingsProvider.snapshot = settingsSnapshot
        let coordinator = SuggestionCoordinator(
            permissionManager: StubSuggestionPermissionProvider(),
            focusModel: StubSuggestionFocusProvider(snapshot: focusSnapshot),
            inputMonitor: inputMonitor,
            overlayController: StubSuggestionOverlayController(state: overlayState),
            suggestionInserter: inserter,
            suggestionEngine: StubSuggestionEngine(),
            suggestionSettings: settingsProvider,
            clipboardContextProvider: StubClipboardContextProvider(),
            clipboardRelevanceFilter: StubClipboardRelevanceFilter(),
            visualContextCoordinator: StubVisualContextCoordinator(),
            interactionState: interactionState,
            workController: SuggestionWorkController(),
            configuration: .standard,
            spellChecker: CurrentWordSpellChecker(),
            symSpellCorrector: SymSpellCorrector(preloadLanguage: nil),
            qualityMetricsStore: SuggestionQualityMetricsStore(
                userDefaults: UserDefaults(suiteName: "CotabbyTests.quality.\(UUID().uuidString)") ?? .standard
            ),
            userDefaults: UserDefaults(suiteName: "CotabbyTests.\(UUID().uuidString)") ?? .standard
        )
        Self.retainedCoordinators.append(coordinator)
        return coordinator
    }
}

@MainActor
private final class StubSuggestionPermissionProvider: SuggestionPermissionProviding {
    var inputMonitoringGranted = true
    var screenRecordingGranted = true

    private let inputSubject = PassthroughSubject<Bool, Never>()
    private let screenSubject = PassthroughSubject<Bool, Never>()

    var inputMonitoringGrantedPublisher: AnyPublisher<Bool, Never> {
        inputSubject.eraseToAnyPublisher()
    }

    var screenRecordingGrantedPublisher: AnyPublisher<Bool, Never> {
        screenSubject.eraseToAnyPublisher()
    }
}

@MainActor
private final class StubSuggestionFocusProvider: SuggestionFocusProviding {
    var snapshot: FocusSnapshot

    private let snapshotSubject = PassthroughSubject<FocusSnapshot, Never>()

    var snapshotPublisher: AnyPublisher<FocusSnapshot, Never> {
        snapshotSubject.eraseToAnyPublisher()
    }

    init(snapshot: FocusSnapshot) {
        self.snapshot = snapshot
    }

    func refreshNow() {}
}

@MainActor
private final class StubSuggestionInputMonitor: SuggestionInputMonitoring {
    var onEvent: ((CapturedInputEvent) -> Bool)?
    var onSuppressedSyntheticInput: (() -> Void)?
    var shouldConsumeAcceptKeyProvider: @MainActor @Sendable () -> Bool = { false }
    private(set) var acceptInterceptionRequests: [Bool] = []

    func setAcceptInterceptionActive(_ active: Bool) {
        acceptInterceptionRequests.append(active)
    }
}

@MainActor
private final class StubSuggestionOverlayController: SuggestionOverlayControlling {
    var state: OverlayState
    var onStateChange: ((OverlayState) -> Void)?

    init(state: OverlayState) {
        self.state = state
    }

    func showSuggestion(_ text: String, geometry: SuggestionOverlayGeometry) {
        state = .visible(text: text, geometry: geometry, mode: .inline)
        onStateChange?(state)
    }

    func hide(reason: String) {
        state = .hidden(reason: reason)
        onStateChange?(state)
    }
}

@MainActor
private final class StubSuggestionInserter: SuggestionInserting {
    var lastErrorMessage: String?
    var insertedChunks: [String] = []
    var replacements: [(deleteCount: Int, text: String)] = []
    var shouldInsert = true

    func insert(_ suggestion: String) -> Bool {
        insertedChunks.append(suggestion)
        return shouldInsert
    }

    func replace(deletingUTF16Count: Int, with text: String) -> Bool {
        replacements.append((deletingUTF16Count, text))
        return shouldInsert
    }
}

private enum StubSuggestionEngineError: Error {
    case unexpectedGeneration
}

@MainActor
private final class StubSuggestionEngine: SuggestionGenerating {
    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        throw StubSuggestionEngineError.unexpectedGeneration
    }

    func resetCachedGenerationContext() async {}
}

@MainActor
private final class StubSuggestionSettingsProvider: SuggestionSettingsProviding {
    var snapshot = CotabbyTestFixtures.settingsSnapshot()

    private let snapshotSubject = PassthroughSubject<SuggestionSettingsSnapshot, Never>()

    var snapshotPublisher: AnyPublisher<SuggestionSettingsSnapshot, Never> {
        snapshotSubject.eraseToAnyPublisher()
    }
}

@MainActor
private final class StubClipboardContextProvider: ClipboardContextProviding {
    var currentChangeCount = 0

    func currentContext() -> String? {
        nil
    }
}

@MainActor
private final class StubClipboardRelevanceFilter: ClipboardRelevanceFiltering {
    func filter(
        clipboard: String?,
        pasteboardChangeCount: Int,
        precedingText: String
    ) -> String? {
        nil
    }
}

@MainActor
private final class StubVisualContextCoordinator: VisualContextCoordinating {
    var status: VisualContextStatus = .idle
    var latestExcerpt: String?
    var onStateChange: ((VisualContextStatus, String?) -> Void)?
    var onInjectedContextReady: ((FocusedInputIdentity) -> Void)?

    func startSessionIfNeeded(for snapshotContext: FocusedInputSnapshot) {}

    func cancel(resetState: Bool) {}

    func excerpt(for context: FocusedInputContext) -> String? {
        nil
    }
}

private func runOnMainActor<Result>(
    _ body: @MainActor () throws -> Result
) rethrows -> Result {
    if Thread.isMainThread {
        return try MainActor.assumeIsolated(body)
    }

    return try DispatchQueue.main.sync {
        try MainActor.assumeIsolated(body)
    }
}
