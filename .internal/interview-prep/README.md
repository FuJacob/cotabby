# Cotabby Interview Study Path

## Purpose

This is an untimed, mastery-based study path for explaining Cotabby in a technical interview. It
does not repeat the detailed architecture guides. It tells you what to read, which concrete symbols
to trace, what decisions to understand, and what you must be able to reconstruct without notes.

The objective is not to memorize the repository. The objective is to internalize the product as a
set of reliability boundaries:

~~~text
process lifecycle
  -> focused editor truth
  -> global input intent
  -> eligible immutable request
  -> selected generation backend
  -> normalized active session
  -> non-activating presentation
  -> validated insertion
  -> host publication reconciliation
~~~

You are ready when you can enter the repository through a symptom or design question, name the
responsible owner, trace the data flow, explain the tradeoff, and identify the invariant that keeps
the user safe.

## Source-of-Truth Order

Use documentation in this order:

1. [Root architecture map](../../ARCHITECTURE.md) for the whole-system mental model.
2. The relevant guide under [architecture](../architecture/) for the subsystem explanation.
3. The linked production source for current behavior.
4. Tests for executable examples and edge cases.

[README.md](../../README.md) is the product-facing overview, while [AGENTS.md](../../AGENTS.md) is the
canonical coding-agent instruction file. Both are synchronized with the three-engine architecture,
but neither replaces the subsystem guides or production source for implementation-level questions.
When any prose conflicts with code and tests, verify the owner directly and fix the documentation.

## How to Study

For each section:

1. Read the named architecture guide.
2. Open the production files in the stated order.
3. Locate the named symbols rather than scrolling randomly.
4. Draw the input, mutable owner, async boundary, output, and stale-result guard.
5. Complete the trace exercise without copying code.
6. Answer the checkpoint questions aloud.
7. Reopen the code only after you have committed to an answer.

When explaining a decision, use this shape:

~~~text
constraint
  -> chosen boundary or mechanism
  -> failure it prevents
  -> cost or tradeoff
  -> evidence in specific files
  -> improvement you would consider
~~~

That format demonstrates engineering judgment. Merely describing the implementation demonstrates
code familiarity but not architectural understanding.

## Mastery Area 1: Product and System Shape

### Read

- [Root architecture map](../../ARCHITECTURE.md)
- [Lifecycle and Composition](../architecture/lifecycle-and-composition.md)
- [Suggestion Pipeline](../architecture/suggestion-pipeline.md)

### Open

1. [CotabbyApp.swift](../../Cotabby/App/Core/CotabbyApp.swift)
2. [AppDelegate.swift](../../Cotabby/App/Core/AppDelegate.swift)
3. [CotabbyAppEnvironment.swift](../../Cotabby/App/Core/CotabbyAppEnvironment.swift)
4. [SuggestionCoordinator.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator.swift)
5. [SuggestionSettingsModel.swift](../../Cotabby/Models/Settings/SuggestionSettingsModel.swift)
6. [SuggestionSettingsData.swift](../../Cotabby/Models/Settings/SuggestionSettingsData.swift)

### Find

- CotabbyApp.body
- AppDelegate.applicationDidFinishLaunching
- AppDelegate.applicationWillTerminate
- CotabbyAppEnvironment.init
- SuggestionCoordinator dependencies, internal state, and the small UI-observed published surface
- SuggestionSettingsModel.domainSettings and snapshot

### Understand

Cotabby is not primarily a text-generation application. It is a cross-process editor integration
whose model call sits in the middle of a longer state machine. Reliability depends on focus truth,
event integrity, stale-work rejection, overlay ownership, insertion correctness, and host
reconciliation.

CotabbyApp declares SwiftUI scenes. CotabbyAppEnvironment constructs one shared dependency graph.
AppDelegate controls when app-scoped side effects begin and end. This prevents duplicate AX polling,
event taps, runtime managers, panels, and settings models.

Settings have one durable owner. SwiftUI continues to bind the model's individual published
properties, `domainSettings` projects them into cohesive product areas, the snapshot freezes the
behavior subset for async work, and the store preserves flat UserDefaults keys.

### Trace Exercise

Draw process startup from the App entry point through environment construction to these services:

- FocusTracker
- InputMonitor
- SuggestionCoordinator
- VisualContextCoordinator
- LlamaRuntimeManager
- InlineCommandCoordinator

For each one, distinguish construction from startup. Then reverse the drawing for process
termination.

### Checkpoints

- Why is constructing a service different from starting it?
- Which subscriptions belong to CotabbyAppEnvironment, and which belong to AppDelegate?
- Why would constructing FocusTracker or InputMonitor inside a SwiftUI view be dangerous?
- Why does the XCTest host skip production startup?
- What resources must be stopped before native runtime shutdown?
- Give a one-minute description of Cotabby without leading with llama.cpp.

## Mastery Area 2: Focus as Eventually Consistent State

### Read

- [Focus and Accessibility](../architecture/focus-and-accessibility.md)
- The privacy boundary in [Context, Privacy, and Permissions](../architecture/context-privacy-and-permissions.md)

### Open

1. [FocusTracker.swift](../../Cotabby/Services/Focus/FocusTracker.swift)
2. [FocusSnapshotResolver.swift](../../Cotabby/Services/Focus/FocusSnapshotResolver.swift)
3. [FocusModels.swift](../../Cotabby/Models/Focus/FocusModels.swift)
4. [AXTextGeometryResolver.swift](../../Cotabby/Services/Focus/AXTextGeometryResolver.swift)
5. [AXHelper.swift](../../Cotabby/Support/Accessibility/AXHelper.swift)

### Find

- FocusTracker.start, refreshNow, performCaptureAndPublish, and resolveChromiumFocusFallback
- FocusSnapshotResolver.resolveSnapshot, resolveCandidate, boundedContextWindow, and candidateSnapshot
- FocusCapability and FocusedInputSnapshot
- CaretGeometryQuality
- AXTextGeometryResolver.resolveCaretRect and its range, marker, character, static-run, and field
  fallback branches

### Understand

AX is synchronous cross-process IPC. Different applications expose different roles, selection
representations, text ranges, and geometry. A FocusSnapshot is therefore a normalized observation,
not permanent truth.

Polling is authoritative because AXObserver coverage and ordering are inconsistent. Explicit refresh
is still a complete capture, not trust in a notification payload. Adaptive backoff reduces idle cost.
Chromium accessibility priming and hit testing recover browser cases that the system-wide focused
element query misses.

Identity is deliberately layered. Element identifiers can be recycled, so focusChangeSequence,
process identity, content signatures, and selection are used according to the downstream invariant.

### Trace Exercise

Trace a focused Gmail editor from FocusTracker.performCaptureAndPublish through
FocusSnapshotResolver.resolveSnapshot. Record:

- How the owning process is determined
- How editable candidates are ranked
- Where text is bounded
- Where secure capability is decided
- How caret geometry receives a quality
- Which values become FocusedInputSnapshot
- What causes a new focusChangeSequence

Repeat conceptually for a native NSTextView and note which compatibility branches disappear.

### Checkpoints

- Why is NSWorkspace.frontmostApplication insufficient?
- Why is an editable AX role insufficient?
- Why bound text before publishing the snapshot rather than only in the prompt renderer?
- What makes exact, derived, estimated, and layoutEstimated geometry different?
- Why does presentation care about geometry quality?
- What can go wrong if a cache is keyed only by elementIdentifier?
- Why are AX calls kept on MainActor despite their latency risk?
- What is the current secure-field acquisition limitation?

## Mastery Area 3: Global Input Without Stealing Keystrokes

### Read

- [Input and Insertion](../architecture/input-and-insertion.md)
- Input handling in [Suggestion Pipeline](../architecture/suggestion-pipeline.md)

### Open

1. [InputMonitor.swift](../../Cotabby/Services/Input/InputMonitor.swift)
2. [InputSuppressionController.swift](../../Cotabby/Services/Input/InputSuppressionController.swift)
3. [KeyboardInputSourceMonitor.swift](../../Cotabby/Services/Input/KeyboardInputSourceMonitor.swift)
4. [InlineCommandCoordinator.swift](../../Cotabby/App/Coordinators/InlineCommandCoordinator.swift)

### Find

- InputMonitor.start and refresh
- installObserverTapIfNeeded
- installAcceptTapIfNeeded
- installToggleTapIfNeeded
- updateAcceptTapState
- handleObserverKeyDown
- handleAcceptKeyDown
- acceptanceKind
- InputMonitorAcceptTapDecision

### Understand

The steady observer is listen-only and cannot consume user input. A separate default tap exists only
while a visible suggestion or inline-command capture needs interception. Even then, a matching key is
consumed only after the current owner returns success. Stale or declined ownership passes the
original event through.

The global toggle has independent lifetime because it must work without a visible suggestion.
InlineCommandCoordinator arbitrates the one capture slot between emoji and macros.

Synthetic insertion events are tagged and covered by bounded suppression so Cotabby does not treat
its own writes as new user typing. Suppression must expire quickly enough that real typing is never
hidden.

### Trace Exercise

Trace one configured word-accept key twice:

1. A valid visible suggestion exists and acceptance succeeds.
2. The consuming tap still exists but the session became stale before the key arrived.

Show exactly why the first event is swallowed and the second reaches the host application.

Then trace one Unicode event posted by SuggestionInserter and explain why neither the listen-only
observer nor the consuming accept tap should treat it as user intent.

### Checkpoints

- Why not install one permanently consuming event tap?
- What does fail-open mean here?
- Why does key recognition read current settings at event time?
- Why does the accept tap linger briefly after the overlay hides?
- Why does a synthetic source marker exist in addition to a suppression count?
- How can emoji use the accept key without racing suggestion acceptance?
- What should happen if Input Monitoring permission is revoked while a suggestion is visible?

## Mastery Area 4: Scheduling and Building a Request

### Read

- [Suggestion Pipeline](../architecture/suggestion-pipeline.md)
- [Context, Privacy, and Permissions](../architecture/context-privacy-and-permissions.md)

### Open

1. [SuggestionCoordinator+Input.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator+Input.swift)
2. [SuggestionCoordinator+Prediction.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator+Prediction.swift)
3. [SuggestionWorkController.swift](../../Cotabby/Services/Suggestion/SuggestionWorkController.swift)
4. [SuggestionAvailabilityEvaluator.swift](../../Cotabby/Support/Suggestion/SuggestionAvailabilityEvaluator.swift)
5. [SuggestionRequestFactory.swift](../../Cotabby/Support/Suggestion/SuggestionRequestFactory.swift)
6. [SuggestionRequest.swift](../../Cotabby/Models/Suggestion/SuggestionRequest.swift)

### Find

- handleFocusSnapshotChange
- handleInputEvent
- schedulePredictionAfterHostPublishDelay
- pollForHostPublish
- schedulePrediction
- generateFromCurrentFocus
- dispatchGeneration
- SuggestionWorkController.replaceDebouncedWork, replaceGenerationWork, isCurrent, and cancelAll
- SuggestionAvailabilityEvaluator.disabledReason
- SuggestionRequestFactory.buildRequest

### Understand

A global keydown often arrives before the host publishes its new AX value. The coordinator therefore
does not immediately assume the snapshot contains the typed character. It debounces, requests fresh
focus state, and performs bounded host-publication polling.

Cancellation is advisory. Native or system work may complete after cancellation, so every unit of
prediction work also carries a monotonically increasing work ID. Result application validates that
ID plus focus, content, session, and settings continuity.

SuggestionRequestFactory separates the question of what to request from when to request. It receives
already captured values, applies engine-specific bounds and optional-context budgets, and returns an
immutable SuggestionRequest with a request ID.

### Trace Exercise

Trace the typed character a from InputMonitor through:

- host-publication delay
- availability evaluation
- work replacement
- fresh focus materialization
- correction gate
- clipboard relevance
- visual excerpt lookup
- request construction
- engine dispatch

At each await, write the condition that could make the work stale.

### Checkpoints

- Why are cancellation and work identity both required?
- Why gate eligibility more than once?
- Why does an engine receive an immutable request rather than a focus service?
- Which optional contexts can enter a request?
- Which layer owns context acquisition, and which owns prompt budgeting?
- Why does the caret prefix receive priority over optional context?
- Why does every request need a correlation ID?
- What is speculative post-acceptance generation, and how is an incorrect speculation rejected?

## Mastery Area 5: Streaming, Sessions, and Reconciliation

### Read

- Streaming, normalization, and sessions in [Suggestion Pipeline](../architecture/suggestion-pipeline.md)
- Presentation stability in [Presentation and Sibling Features](../architecture/presentation-and-sibling-features.md)

### Open

1. [SuggestionCoordinator+Prediction.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator+Prediction.swift)
2. [SuggestionInteractionState.swift](../../Cotabby/Services/Suggestion/SuggestionInteractionState.swift)
3. [SuggestionSessionReconciler.swift](../../Cotabby/Support/Suggestion/SuggestionSessionReconciler.swift)
4. [SuggestionTextNormalizer.swift](../../Cotabby/Support/Suggestion/SuggestionTextNormalizer.swift)
5. [CompletionSeamGuard.swift](../../Cotabby/Support/Suggestion/CompletionSeamGuard.swift)
6. [StreamedGhostTextPolicy.swift](../../Cotabby/Support/Suggestion/StreamedGhostTextPolicy.swift)
7. [SuggestionStreamingState.swift](../../Cotabby/Support/Suggestion/SuggestionStreamingState.swift)

### Find

- queueStreamedPartial, drainStreamedPartial, and applyStreamedPartial
- SuggestionStreamingState.beginGeneration, enqueue, drain, canRender, and clearSession
- apply(result:workID:)
- SuggestionInteractionState.startSession and reconcileActiveSession
- advanceIfTypedCharactersMatch
- SuggestionSessionReconciler.reconcile
- nextAcceptanceChunk and nextAcceptancePhrase
- SuggestionTextNormalizer.normalizeDetailed

### Understand

Streamed partials are cumulative and provisional. SuggestionStreamingState makes pending partials
latest-wins, permits only one scheduled drain per runloop window, and remembers the monotonic rendered
prefix. The coordinator still owns scheduling, freshness checks, session mutation, and AppKit. A
partial can become a real active session so the user can accept before decoding ends, but the final
result can replace or suppress it.

SuggestionInteractionState owns mutable session facts. SuggestionSessionReconciler owns pure
comparison rules. This split lets acceptance, type-through, trailing-text checks, CJK segmentation,
and known post-insertion lag be tested without running AX or AppKit.

### Trace Exercise

Start with the visible suggestion:

~~~text
 meeting tomorrow at 10
~~~

Trace these independent cases:

- The user types the exact leading space and m
- The user types a divergent character
- The user accepts one word
- The user accepts the full tail
- AX briefly reports the pre-insertion value
- The final model result is rejected after a partial was displayed

Identify which owner changes session state and which pure rule decides the transition.

### Checkpoints

- Why can a streamed partial become accept-ready?
- Why must the final result remain authoritative?
- What is the invariant between visible overlay text and remaining session text?
- Why is post-insertion AX tolerance represented by a narrow sentinel?
- How does exact type-through avoid unnecessary regeneration?
- Why are corrections represented as a different session kind?
- Where do language-specific acceptance rules belong?

## Mastery Area 6: Presentation and Insertion

### Read

- [Presentation and Sibling Features](../architecture/presentation-and-sibling-features.md)
- [Input and Insertion](../architecture/input-and-insertion.md)

### Open

1. [SuggestionOverlayPresenter.swift](../../Cotabby/Services/Suggestion/SuggestionOverlayPresenter.swift)
2. [OverlayController.swift](../../Cotabby/Services/Presentation/OverlayController.swift)
3. [CompletionRenderModePolicy.swift](../../Cotabby/Support/Presentation/CompletionRenderModePolicy.swift)
4. [SuggestionOverlayStabilityGate.swift](../../Cotabby/Support/Presentation/SuggestionOverlayStabilityGate.swift)
5. [SuggestionCoordinator+Acceptance.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator+Acceptance.swift)
6. [SuggestionInserter.swift](../../Cotabby/Services/Suggestion/SuggestionInserter.swift)
7. [InsertionSafetyGate.swift](../../Cotabby/Support/Suggestion/InsertionSafetyGate.swift)
8. [InsertionStrategySelector.swift](../../Cotabby/Support/Suggestion/InsertionStrategySelector.swift)
9. [PostExhaustionAcceptanceState.swift](../../Cotabby/Support/Suggestion/PostExhaustionAcceptanceState.swift)

### Find

- SuggestionOverlayPresenter.present
- OverlayController.showSuggestion, showInline, showMirror, and advanceInline
- CompletionRenderModePolicy.mode
- acceptCurrentSuggestion, acceptEntireSuggestion, and acceptEnabledSuggestion
- presentAdvancedOverlay and schedulePostInsertionRefresh
- armPostExhaustionAcceptance and flushQueuedPostExhaustionAcceptIfNeeded
- SuggestionInserter.insert, replace, insertViaPaste, and pressPasteMenuItem

### Understand

The panel is borderless, non-activating, mouse-ignoring, and space/full-screen compatible. AppKit owns
window behavior; SwiftUI describes its contents.

Automatic mode paints inline only with exact or derived geometry and a safe end-of-line seam.
Estimated, layout-estimated, and mid-line cases use a mirror card. This avoids visually pretending
that approximate geometry identifies an exact glyph position.

Short ordinary insertions use Unicode CGEvents. A composing IME uses paste because a Unicode event
can re-enter composition. Optional long/multiline paste snapshots every pasteboard representation,
tries the target application's AX Paste menu item, falls back to Command-V, and restores only if the
clipboard has not changed.

### Trace Exercise

Trace a partial word acceptance from acceptCurrentSuggestion through session preparation, insertion,
overlay advance, post-insertion sentinel, focus refresh, and session reconciliation.

Repeat for:

- A Japanese IME-active field
- A Chrome field where synthetic Command-V fails
- A correction that replaces a typo
- A user clipboard change during the restore delay

### Checkpoints

- Why does OverlayController own NSPanel instead of SuggestionCoordinator?
- Why is layoutEstimated still a mirror-card quality?
- Why can the overlay advance without waiting for fresh AX geometry?
- What protects the user's clipboard during overlapping paste insertions?
- Why is posting a CGEvent not proof that insertion succeeded?
- Why must acceptance validate both the session and visible overlay?
- Why can rapid Tab queue only one unseen accept while an exhausted tail regenerates?
- How does the generation-keyed backstop guarantee Tab ownership returns to the host?
- What is the safest behavior when any acceptance precondition fails?

## Mastery Area 7: The Three Generation Backends

### Read

- [Inference and Prompting](../architecture/inference-and-prompting.md)
- Engine privacy in [Context, Privacy, and Permissions](../architecture/context-privacy-and-permissions.md)

### Open

1. [SuggestionEngineRouter.swift](../../Cotabby/Services/Runtime/SuggestionEngineRouter.swift)
2. [FoundationModelSuggestionEngine.swift](../../Cotabby/Services/Runtime/FoundationModelSuggestionEngine.swift)
3. [LlamaSuggestionEngine.swift](../../Cotabby/Services/Runtime/LlamaSuggestionEngine.swift)
4. [LlamaRuntimeManager.swift](../../Cotabby/Services/Runtime/LlamaRuntimeManager.swift)
5. [LlamaRuntimeCore.swift](../../Cotabby/Services/Runtime/LlamaRuntimeCore.swift)
6. [OpenAICompatibleSuggestionEngine.swift](../../Cotabby/Services/Runtime/OpenAICompatibleSuggestionEngine.swift)
7. [OpenAICompatibleAPIClient.swift](../../Cotabby/Services/Runtime/OpenAICompatibleAPIClient.swift)
8. [BaseCompletionPromptRenderer.swift](../../Cotabby/Support/Prompting/BaseCompletionPromptRenderer.swift)
9. [FoundationModelPromptRenderer.swift](../../Cotabby/Support/Prompting/FoundationModelPromptRenderer.swift)

### Find

- SuggestionEngineRouter.generateSuggestion, prewarm, resetCachedGenerationContext, and
  generateOpenSourceFallback
- FoundationModelSuggestionEngine.ensureSession
- LlamaSuggestionEngine.generateSuggestion and resetCachedGenerationContext
- LlamaRuntimeManager.prepare, generate, stop, stopAndWait, and shutdownSync
- LlamaRuntimeCore.prepare, generate, preparedPrompt, obtainAutocompleteSequence,
  resetPromptCache, and shutdown
- OpenAICompatibleSuggestionEngine.generateSuggestion and prewarm
- BaseCompletionPromptRenderer.prompt
- FoundationModelPromptRenderer.sessionInstructions and prompt

### Understand

The router provides one generation contract while preserving backend-specific lifecycle:

- Apple uses an instruction channel and one-use compatible prewarmed session.
- Llama uses a base completion prompt, in-process native pointers, prompt token/KV reuse, token
  streaming, and explicit shutdown.
- An OpenAI-compatible endpoint uses completion or chat request transport and SSE parsing. It may be
  loopback, LAN, or public HTTPS.

LlamaRuntimeManager is MainActor and publishes user-facing state. LlamaRuntimeCore is a nonisolated,
lock/condition-protected class that owns native correctness. It is not a Swift actor. The
autocomplete lock serializes prompt-cache/decode state; lifecycle coordination protects load,
active operations, abort, and shutdown.

### Trace Exercise

Take one SuggestionRequest and trace it separately through all three engines. For each path identify:

- Prompt shape
- Prewarm behavior
- Streaming mechanism
- Cancellation mechanism
- Cache or session state
- Output normalization
- Error classification
- Privacy boundary
- Cleanup behavior

Then trace an engine switch from Open Source to endpoint and explain why the llama runtime is stopped.

### Checkpoints

- Why does Apple have a narrow fallback to llama rather than universal silent fallback?
- Why are base GGUF prompts continuation-shaped?
- Why does the caret prefix come last?
- Why is LlamaRuntimeCore not simply MainActor-isolated?
- Why use explicit locking instead of casually wrapping native pointers in Task calls?
- What is safe KV-cache reuse?
- Why broadcast context reset to every backend?
- What data can leave the Mac in endpoint mode?
- Why reject insecure public HTTP but allow loopback HTTP?

## Mastery Area 8: Context, Permissions, and Honest Privacy

### Read

- [Context, Privacy, and Permissions](../architecture/context-privacy-and-permissions.md)

### Open

1. [PermissionManager.swift](../../Cotabby/Services/Permission/PermissionManager.swift)
2. [PermissionGuidanceController.swift](../../Cotabby/Services/Permission/PermissionGuidanceController.swift)
3. [ClipboardContextProvider.swift](../../Cotabby/Services/Context/ClipboardContextProvider.swift)
4. [ClipboardRelevanceFilter.swift](../../Cotabby/Support/Context/ClipboardRelevanceFilter.swift)
5. [VisualContextCoordinator.swift](../../Cotabby/Services/Visual/VisualContextCoordinator.swift)
6. [WindowScreenshotService.swift](../../Cotabby/Services/Visual/WindowScreenshotService.swift)
7. [ScreenTextExtractor.swift](../../Cotabby/Services/Visual/ScreenTextExtractor.swift)
8. [OCRTextHygiene.swift](../../Cotabby/Support/Context/OCRTextHygiene.swift)
9. [PromptContextSanitizer.swift](../../Cotabby/Support/Context/PromptContextSanitizer.swift)
10. [OpenAICompatibleEndpointModels.swift](../../Cotabby/Models/Runtime/OpenAICompatibleEndpointModels.swift)

### Find

- PermissionManager.refresh and requiredPermissionsGranted
- ClipboardRelevanceFilter.filter
- VisualContextCoordinator.startSessionIfNeeded, launchSession, and applyExcerpt
- ScreenshotContextGenerator.generateContext and finishedExcerpt
- OCRTextHygiene.clean
- OpenAICompatibleEndpointConfiguration validation and privacyWarning
- SuggestionAvailabilityEvaluator.shouldCaptureVisualContext

### Understand

Accessibility and Input Monitoring are required for core autocomplete. Screen Recording is optional.
Visual context is a field-scoped screenshot-to-Vision-OCR pipeline. OCR confidence and hygiene remove
noise; no model summarization occurs; only a bounded sanitized excerpt can reach a prompt.

Clipboard context is read at request time, relevance-filtered, distilled, and not retained as a
history. User-authored context, surface metadata, and visual context have independent budgets.

Privacy claims must distinguish on-device Apple/llama generation from a configured endpoint. They
must also describe the current secure-field limitation honestly: generation and insertion are
blocked, but a bounded FocusedInputSnapshot is still created and visual capture can run because the
visual eligibility gate ignores capability.

### Trace Exercise

Build a context inventory for one request. For each field record:

- Acquisition owner
- Permission
- In-memory lifetime
- First bound
- Prompt budget
- Whether it can be logged in debug mode
- Whether it leaves the Mac under each engine

Then trace a secure field far enough to show where assistance stops and where acquisition currently
does not.

### Checkpoints

- Why is Screen Recording optional?
- Why is visual context scoped to a field instead of regenerated on every key?
- Why is raw OCR cleaned rather than summarized by another model?
- Why does relevance filtering matter for clipboard context?
- What exactly does local-first mean in the current product?
- Where are endpoint credentials stored?
- Which privacy claim would currently be false?
- How would you move toward a true no-secure-field-acquisition invariant?

## Mastery Area 9: Observability, Tests, and Failure Diagnosis

### Read

- Debugging and validation in [Root architecture map](../../ARCHITECTURE.md)
- Failure-oriented sections in every architecture guide

### Open

1. [CotabbyDebugOptions.swift](../../Cotabby/Support/Logging/CotabbyDebugOptions.swift)
2. [RequestID.swift](../../Cotabby/Support/Logging/RequestID.swift)
3. [SuggestionDebugLogger.swift](../../Cotabby/Services/Suggestion/SuggestionDebugLogger.swift)
4. [FileLogHandler.swift](../../Cotabby/Support/Logging/FileLogHandler.swift)
5. [LLMIOFileHandler.swift](../../Cotabby/Support/Logging/LLMIOFileHandler.swift)
6. [CotabbyTests](../../CotabbyTests)
7. [build workflow](../../.github/workflows/build.yml)
8. [test workflow](../../.github/workflows/tests.yml)
9. [XcodeGen workflow](../../.github/workflows/xcodegen.yml)
10. [lint workflow](../../.github/workflows/lint.yml)

### Understand

A request ID joins coordinator stages, backend selection, generation, performance, acceptance, and
debug LLM I/O. The always-on path uses unified logging. Explicit -cotabby-debug enables local JSONL,
full prompts/completions, AX dumps, and visual capture artifacts.

Tests are strongest around deterministic Support and Models rules. Stateful owners expose narrow
protocols and fakes so work identity, session transitions, trigger machines, prompt rendering, and
layout policy can run without global permissions.

XcodeGen makes project.yml the project source of truth. CI intentionally treats a regenerated
project diff as a failure.

### Trace Exercise

For each symptom, identify the first log category, correlation key, production file, and pure test
surface:

- A suggestion from the previous field appears
- Tab is swallowed without insertion
- A Chrome caret is one line too low
- Llama remains resident after switching engines
- Visual context belongs to the previous field
- A final result suppresses a streamed partial

### Checkpoints

- Why is a request ID more useful than chronological logs alone?
- Which debug artifacts can contain private text?
- What should be unit tested without launching the app?
- What requires a real host-application compatibility test?
- Why are build, tests, lint, and XcodeGen separate CI checks?
- What would you instrument before trying to fix an intermittent editor bug?

## The Six Golden Traces

You should be able to draw these from memory and name the files at every arrow.

### Trace 1: Process Startup

~~~text
CotabbyApp
  -> AppDelegate.init
  -> CotabbyAppEnvironment.init
  -> applicationDidFinishLaunching
  -> runtime / focus / input / suggestion / inline command startup
~~~

### Trace 2: Focus Acquisition

~~~text
FocusTracker poll
  -> focused AX element or browser fallback
  -> FocusSnapshotResolver
  -> bounded FocusedInputSnapshot + capability
  -> FocusTrackingModel publication
  -> SuggestionCoordinator focus reaction
~~~

### Trace 3: Typed Character to Streamed Ghost Text

~~~text
listen-only input event
  -> host-publication refresh
  -> availability
  -> work ID
  -> request factory
  -> engine router
  -> normalized cumulative partial
  -> active session
  -> overlay presenter
~~~

### Trace 4: Word Acceptance

~~~text
conditional consuming tap
  -> session + overlay validation
  -> next acceptance chunk
  -> SuggestionInserter
  -> synchronous tail advance
  -> post-insertion AX sentinel
  -> fresh snapshot reconciliation
  -> bounded post-exhaustion ownership if the tail ended
~~~

### Trace 5: Field Switch During Generation

~~~text
new focus sequence
  -> cancel old tasks
  -> increment work identity
  -> reset backend context
  -> clear old session / overlay
  -> late old result rejected by current-work and focus/content checks
~~~

### Trace 6: Engine Switch

~~~text
settings/profile selection
  -> cancel prediction
  -> reset cached generation context
  -> router selects backend
  -> AppDelegate starts or stops llama runtime
  -> selected backend prewarm
~~~

## Interview Readiness Checklist

### Product

- Explain Cotabby in one minute without reducing it to an LLM wrapper.
- State the required and optional permissions.
- Explain local-first without falsely claiming every engine is offline.
- Name the supported presentation and acceptance modes.

### Ownership

- Identify the composition root and lifecycle owner.
- Explain why views do not construct process-wide services.
- Distinguish coordinator orchestration, service side effects, model state, and pure Support rules.
- Explain why both environment and AppDelegate retain subscriptions.

### Reliability

- Explain focus eventual consistency.
- Explain cancellation plus work identity.
- Explain focus/content/session revalidation after awaits.
- Explain fail-open input consumption.
- Explain post-insertion reconciliation.
- Explain streamed partial versus authoritative final.
- Explain latest-wins stream draining and the bounded post-exhaustion rapid-accept window.

### macOS

- Explain the roles of Accessibility, Input Monitoring, and Screen Recording.
- Explain why AppKit panels are needed next to SwiftUI.
- Explain browser/Electron compatibility work.
- Explain IME-safe insertion and clipboard restoration.
- Explain TCC identity and why Cotabby Dev is separate.

### Inference

- Compare Apple, llama, and endpoint prompt/stream/lifecycle behavior.
- Explain manager versus core ownership.
- Explain safe prompt/KV reuse.
- Explain backend-independent normalization.
- Explain when data can leave the machine.

### Critical Judgment

- Identify current architecture strengths.
- Identify current complexity or debt without being dismissive.
- Explain the secure-field acquisition limitation honestly.
- Propose a measured improvement rather than a rewrite.
- Translate the invariants into a reliability plan for HyperWrite.

## Final Active-Recall Drill

Close the codebase and answer:

1. What are the three most dangerous races in Cotabby?
2. What are the three ways Cotabby could accidentally interfere with another application?
3. Which owner is responsible for preventing each one?
4. Where does untrusted or stale information become a stable domain value?
5. Which state is app-scoped, field-scoped, request-scoped, session-scoped, and token-stream-scoped?
6. What happens when the host never publishes the insertion Cotabby expected?
7. What happens when the user switches engines during decode?
8. Which work stays on MainActor and which work must leave it?
9. Which claims are product promises, and which are current implementation limitations?
10. Which Cotabby patterns should transfer to HyperWrite, and which should be reconsidered?

If an answer is vague, return to the named trace rather than rereading the repository from the
beginning.
