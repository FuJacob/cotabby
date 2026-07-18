# Cotabby Technical Decision Question Bank

## How to Use This Bank

These are not scripts to recite word for word. Learn the reasoning, then answer in your own voice.
Every strong answer should contain:

1. The product or platform constraint
2. The chosen design
3. The failure it prevents
4. The cost or compromise
5. A concrete file or type
6. What you would improve with more time

When Josh asks a short question, begin with the direct decision and stop after the tradeoff. Let him
pull you deeper. When he asks for a deep dive, use the source trail to walk from event to owner to
invariant.

## Product and System Architecture

### 1. What is the architecture of Cotabby?

**Strong answer**

Cotabby is a long-lived macOS menu bar agent organized around a cross-application autocomplete state
machine. It continuously reduces Accessibility state into a bounded FocusSnapshot, observes global
input without taking focus, builds an immutable request, routes it through one of three generation
backends, normalizes the output, materializes an active suggestion session, renders through a
non-activating AppKit panel, and validates insertion back into the host.

The model is only one stage. Most reliability work is around eventual AX state, stale async work,
input ownership, geometry quality, and proving that an insertion actually reached another process.

The dependency graph is constructed once by CotabbyAppEnvironment. AppDelegate controls startup and
shutdown. SuggestionCoordinator owns orchestration while pure rules live in Support and side effects
live in Services.

**Source trail**

- [CotabbyAppEnvironment.swift](../../Cotabby/App/Core/CotabbyAppEnvironment.swift)
- [AppDelegate.swift](../../Cotabby/App/Core/AppDelegate.swift)
- [SuggestionCoordinator.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator.swift)
- [Root architecture map](../../ARCHITECTURE.md)

**Avoid**

Do not answer, “It watches typing and calls llama.cpp.” That omits Apple, endpoints, insertion, and
the hard cross-process parts.

### 2. What was the hardest technical part?

**Strong answer**

The hardest part is maintaining one coherent editing session across independent, eventually
consistent systems. CGEvents report the physical input before many applications publish their new
text through AX. AX elements can be replaced or recycled. Model work finishes asynchronously. The
overlay is in Cotabby's process while the caret is in another process. Synthetic insertion is a
request, not proof that the host mutated.

The response was to make freshness explicit: work IDs, focusChangeSequence, bounded content
signatures, session anchors, overlay/session equality, post-insertion sentinels, and repeated
validation after awaits.

**Source trail**

- [SuggestionCoordinator+Input.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator+Input.swift)
- [SuggestionWorkController.swift](../../Cotabby/Services/Suggestion/SuggestionWorkController.swift)
- [SuggestionInteractionState.swift](../../Cotabby/Services/Suggestion/SuggestionInteractionState.swift)
- [SuggestionSessionReconciler.swift](../../Cotabby/Support/Suggestion/SuggestionSessionReconciler.swift)

### 3. Why split App, Services, Models, Support, and UI?

**Strong answer**

The split follows change risk and side-effect ownership. Support holds deterministic policy, Models
hold shared values and contracts, Services own OS/native/network side effects, App coordinates them,
and UI renders state. That lets us test the acceptance rule or prompt budget without installing an
event tap or creating a panel.

The tradeoff is more types and navigation. The benefit is that platform quirks do not become
unreviewable branches inside one coordinator. The split is useful only when each boundary owns a real
invariant; I would not create a file for every small function.

**Source trail**

- [SuggestionAvailabilityEvaluator.swift](../../Cotabby/Support/Suggestion/SuggestionAvailabilityEvaluator.swift)
- [SuggestionSubsystemContracts.swift](../../Cotabby/Models/Suggestion/SuggestionSubsystemContracts.swift)
- [SuggestionInserter.swift](../../Cotabby/Services/Suggestion/SuggestionInserter.swift)
- [SuggestionCoordinator.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator.swift)

### 4. Is SuggestionCoordinator too large?

**Strong answer**

It is still a high-complexity owner because the product loop has many transitions, but it is no
longer intended as one monolithic algorithm. Its extensions separate lifecycle, input, prediction,
and acceptance. Mutable sub-state and pure decisions have moved into SuggestionWorkController,
SuggestionInteractionState, SuggestionAvailabilityEvaluator, SuggestionRequestFactory, and
SuggestionSessionReconciler. SuggestionStreamingState now owns partial coalescing/monotonic-render
bookkeeping, while PostExhaustionAcceptanceState owns the bounded rapid-Tab transition rules.

I would not split the coordinator into independent actors merely to reduce file size because the
transitions need one MainActor ordering domain. I would continue extracting cohesive policies and
small state machines where they can be tested without duplicating ownership.

**Source trail**

- [SuggestionCoordinator.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator.swift)
- [SuggestionCoordinator+Lifecycle.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator+Lifecycle.swift)
- [SuggestionCoordinator+Input.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator+Input.swift)
- [SuggestionCoordinator+Prediction.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator+Prediction.swift)
- [SuggestionCoordinator+Acceptance.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator+Acceptance.swift)
- [SuggestionStreamingState.swift](../../Cotabby/Support/Suggestion/SuggestionStreamingState.swift)
- [PostExhaustionAcceptanceState.swift](../../Cotabby/Support/Suggestion/PostExhaustionAcceptanceState.swift)

### 4A. Why introduce domain settings without migrating persistence?

**Strong answer**

The settings model accumulated fields from several product areas, but SwiftUI bindings, tests, and
UserDefaults keys already formed a compatibility surface. Replacing all of that at once would mix an
ownership improvement with a risky persistence migration.

SuggestionSettingsData groups values into general, engine, completion, context, correction,
presentation, inline-feature, and shortcut domains. SuggestionSettingsModel projects its existing
published properties into that value, snapshots derive behavior from it, and SuggestionSettingsStore
continues mapping to the established flat keys. That improves the mental model without creating two
mutable sources or invalidating saved preferences.

The tradeoff is a temporary forwarding layer. I would migrate consumers domain by domain only where
the cohesive value improves ownership, then remove compatibility accessors when call-site evidence
says it is safe.

**Source trail**

- [SuggestionSettingsData.swift](../../Cotabby/Models/Settings/SuggestionSettingsData.swift)
- [SuggestionSettingsModel.swift](../../Cotabby/Models/Settings/SuggestionSettingsModel.swift)
- [SuggestionSettingsStore.swift](../../Cotabby/Support/Settings/SuggestionSettingsStore.swift)
- [SuggestionSettingsDomainTests.swift](../../CotabbyTests/Models/Settings/SuggestionSettingsDomainTests.swift)

## Ownership and Lifecycle

### 5. Why is there one long-lived dependency graph?

**Strong answer**

Cotabby owns process-wide resources: Accessibility polling, event taps, runtime memory, settings,
panels, downloads, and permission state. If a SwiftUI redraw created a second FocusTracker or
InputMonitor, we could poll twice, consume a key twice, race model reloads, or display state from a
different settings instance.

CotabbyAppEnvironment constructs those objects once and passes narrow collaborators into
coordinators. AppDelegate starts and stops side effects at process lifecycle boundaries. The cost is
a large composition root, but that cost is visible and deterministic.

**Source trail**

- [CotabbyApp.swift](../../Cotabby/App/Core/CotabbyApp.swift)
- [CotabbyAppEnvironment.swift](../../Cotabby/App/Core/CotabbyAppEnvironment.swift)
- [AppDelegate.swift](../../Cotabby/App/Core/AppDelegate.swift)

### 6. Why do AppDelegate and CotabbyAppEnvironment both retain subscriptions?

**Strong answer**

They own different relationships. The environment retains relationships among the objects it
constructed, such as settings changing focus cadence, power profiles selecting engines, or endpoint
identity invalidating connection state. AppDelegate retains reactions tied to process lifecycle,
such as permissions refreshing input monitoring, engine changes loading or releasing llama, and
focus changes moving activation/debug overlays.

The distinction is ownership, not “all subscriptions belong in one file.” If the environment did not
retain its cancellables for the process lifetime, graph-internal behavior would silently stop.

**Source trail**

- [CotabbyAppEnvironment.swift](../../Cotabby/App/Core/CotabbyAppEnvironment.swift)
- [AppDelegate.swift](../../Cotabby/App/Core/AppDelegate.swift)
- [Lifecycle and Composition](../architecture/lifecycle-and-composition.md)

### 7. Why is native runtime shutdown synchronous at termination?

**Strong answer**

The llama context and Metal/native resources outlive ordinary Swift objects and can collide with C++
static teardown if the process exits while work is active. AppDelegate first stops new coordination
and global input, then asks LlamaRuntimeManager for a bounded synchronous shutdown. LlamaRuntimeCore
prevents new work, aborts or waits for active operations under its lifecycle condition, and releases
native state.

The tradeoff is that termination can wait briefly. The wait must be bounded because permission flows
sometimes require a prompt quit and relaunch.

**Source trail**

- [AppDelegate.swift](../../Cotabby/App/Core/AppDelegate.swift)
- [LlamaRuntimeManager.swift](../../Cotabby/Services/Runtime/LlamaRuntimeManager.swift)
- [LlamaRuntimeCore.swift](../../Cotabby/Services/Runtime/LlamaRuntimeCore.swift)

## Accessibility and Editor Compatibility

### 8. Why poll Accessibility instead of using AXObserver notifications?

**Strong answer**

AX notifications are incomplete and inconsistent across AppKit, browsers, Electron, and custom
editors. Mixing notification and polling streams also creates an ordering problem: which observation
is authoritative when they disagree?

Cotabby uses one rule: a full capture is truth for that moment, and later captures repair stale
state. Activity can request refreshNow, but that still performs a capture rather than trusting the
event payload. Adaptive backoff reduces the idle cost.

The tradeoff is synchronous AX IPC and periodic wakeups, so deep walks are bounded, throttled, cached,
and skipped when Cotabby is disabled.

**Source trail**

- [FocusTracker.swift](../../Cotabby/Services/Focus/FocusTracker.swift)
- [FocusPollBackoff.swift](../../Cotabby/Support/Focus/FocusPollBackoff.swift)
- [Focus and Accessibility](../architecture/focus-and-accessibility.md)

### 9. How do you support Chrome and Electron?

**Strong answer**

Browser editors often expose the focused text node only after web accessibility is primed, and
out-of-process iframes can make the system focused-element query point at the wrong process or miss
the editor. Cotabby primes Chromium accessibility, resolves the actual owning application, and has a
cursor hit-test fallback that is cached only while it remains focused and belongs to the same browser
context.

For geometry, browsers may expose text-marker bounds rather than reliable NSRange bounds. The
resolver tries marker geometry and static text runs before field estimation. Every fallback is
revalidated so it cannot mask a real focus change.

**Source trail**

- [FocusTracker.swift](../../Cotabby/Services/Focus/FocusTracker.swift)
- [ChromiumAccessibilityEnabler.swift](../../Cotabby/Services/Focus/ChromiumAccessibilityEnabler.swift)
- [FocusSnapshotResolver.swift](../../Cotabby/Services/Focus/FocusSnapshotResolver.swift)
- [AXTextGeometryResolver.swift](../../Cotabby/Services/Focus/AXTextGeometryResolver.swift)

### 10. Why classify caret geometry quality?

**Strong answer**

An AX rectangle is not automatically an exact caret. Direct range bounds and derived nearby-character
bounds are precise enough for inline glyphs. A field-frame estimate may only identify the text line,
and hidden TextKit layout is still an estimate of a foreign editor.

Cotabby carries exact, derived, estimated, or layoutEstimated quality into presentation.
CompletionRenderModePolicy uses inline for exact/derived and a mirror card for estimates or a
mid-line caret. That makes uncertainty visible in the UI instead of painting text over host content.

The tradeoff is two presentation modes and more layout policy. It is preferable to confidently wrong
inline placement.

**Source trail**

- [FocusModels.swift](../../Cotabby/Models/Focus/FocusModels.swift)
- [AXTextGeometryResolver.swift](../../Cotabby/Services/Focus/AXTextGeometryResolver.swift)
- [CompletionRenderModePolicy.swift](../../Cotabby/Support/Presentation/CompletionRenderModePolicy.swift)
- [OverlayController.swift](../../Cotabby/Services/Presentation/OverlayController.swift)

### 11. Why keep AX work on MainActor if it can be slow?

**Strong answer**

AX element access, AppKit state, focus caches, and publication are tightly coupled to main-thread
state. MainActor gives capture and cache mutation one ordering domain and avoids unsafe concurrent use
of Core Foundation/AX objects.

The design does not pretend this is free. It bounds text, gates parameterized calls, caches
focus-session invariants, throttles deep descendants/static runs, and uses freshness checks to avoid
duplicate captures. OCR and model generation leave MainActor because they do not need live AX
objects.

If profiling identified a specific safe extraction that could move off actor, I would introduce a
value-type boundary first rather than pass AXUIElement into arbitrary tasks.

**Source trail**

- [FocusTracker.swift](../../Cotabby/Services/Focus/FocusTracker.swift)
- [FocusSnapshotResolver.swift](../../Cotabby/Services/Focus/FocusSnapshotResolver.swift)
- [AXHelper.swift](../../Cotabby/Support/Accessibility/AXHelper.swift)

## Async State and Reliability

### 12. Why are cancellation and work IDs both necessary?

**Strong answer**

Task cancellation expresses intent, but an API or native decode can finish after cancellation was
requested. If result application only checked Task.isCancelled, a previous field's completion could
still appear.

SuggestionWorkController increments a work ID whenever debounce/generation is replaced. A result can
apply only if its captured ID remains current. The coordinator also checks focus, content, settings,
and session signatures because a current task can still be invalidated by environment changes.

The small cost is carrying identity through async boundaries. It converts a timing assumption into an
explicit invariant.

**Source trail**

- [SuggestionWorkController.swift](../../Cotabby/Services/Suggestion/SuggestionWorkController.swift)
- [SuggestionCoordinator+Prediction.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator+Prediction.swift)

### 13. How do you handle a key event arriving before AX publishes the new value?

**Strong answer**

The listen-only CGEvent observes the key before many hosts update AXValue. Cotabby schedules after a
short debounce, requests a fresh capture, and performs bounded host-publication polling when it knows
the host is catching up. It also tracks capture freshness to avoid paying for redundant AX walks.

There is a ceiling. Cotabby cannot wait forever for a broken host, so it eventually proceeds through
ordinary request and stale-result guards. This is one reason the pipeline is designed around eventual
consistency rather than assuming event order.

**Source trail**

- [SuggestionCoordinator+Input.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator+Input.swift)
- [FocusTracker.swift](../../Cotabby/Services/Focus/FocusTracker.swift)

### 14. Why do you revalidate at several pipeline stages?

**Strong answer**

Eligibility is not a lease. Passing it before debounce does not authorize work after the user changes
fields, selects text, disables an app, switches engines, or accepts part of another session.

Cotabby gates before scheduling to avoid waste, again before request construction, and again before
partial/final application and insertion. Each boundary checks the facts that could have changed while
awaiting.

The tradeoff is repeated-looking guard code. Consolidating all guards into one early check would be
shorter but incorrect.

**Source trail**

- [SuggestionAvailabilityEvaluator.swift](../../Cotabby/Support/Suggestion/SuggestionAvailabilityEvaluator.swift)
- [SuggestionCoordinator+Prediction.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator+Prediction.swift)
- [SuggestionCoordinator+Acceptance.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator+Acceptance.swift)

### 15. Why have a separate active suggestion session?

**Strong answer**

A completion is not just a string. It has an anchor focus/content signature, original prefix,
trailing text, consumed character count, kind, and expected host state. The user can type through it,
accept one chunk, switch fields, undo, select text, or race AX publication.

SuggestionInteractionState owns mutable session facts. SuggestionSessionReconciler contains pure
transition rules. This makes the lifecycle explicit and testable rather than comparing the current
overlay string opportunistically.

**Source trail**

- [ActiveSuggestionSession.swift](../../Cotabby/Models/Suggestion/ActiveSuggestionSession.swift)
- [SuggestionInteractionState.swift](../../Cotabby/Services/Suggestion/SuggestionInteractionState.swift)
- [SuggestionSessionReconciler.swift](../../Cotabby/Support/Suggestion/SuggestionSessionReconciler.swift)

### 16. Why can a streamed partial be accepted before generation finishes?

**Strong answer**

Autocomplete is latency-sensitive. If a cumulative partial is normalized, passes seam checks, and
materializes into the same session model as a final result, the user can act on useful text while
decode continues.

SuggestionStreamingState makes pending partials latest-wins, permits one scheduled drain at a time,
and applies the monotonic rendering rule. The coordinator owns the runloop scheduling, freshness
checks, session creation, and overlay effects. The final is still authoritative: it can replace or
suppress a partial. Acceptance or new typing cancels or supersedes remaining work through the normal
work-ID rules.

The tradeoff is more complex session coordination, but it reduces perceived latency without creating
a second acceptance system.

**Source trail**

- [StreamedGhostTextPolicy.swift](../../Cotabby/Support/Suggestion/StreamedGhostTextPolicy.swift)
- [SuggestionStreamingState.swift](../../Cotabby/Support/Suggestion/SuggestionStreamingState.swift)
- [SuggestionCoordinator+Prediction.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator+Prediction.swift)
- [SuggestionInteractionState.swift](../../Cotabby/Services/Suggestion/SuggestionInteractionState.swift)

## Input and Insertion

### 17. How do you guarantee Cotabby does not steal user keys?

**Strong answer**

The steady event tap is listen-only. The only suggestion tap capable of returning nil is installed
while interception is needed, and it consumes a configured key only after the current coordinator
successfully accepts. If the overlay disappeared, the session is stale, permission changed, or
insertion validation fails, the event passes through.

That is fail-open behavior: uncertainty favors the host application. The global toggle has a separate
tap because its ownership is independent of suggestion visibility.

There is one tightly bounded exception to overlay visibility: after the final visible chunk is
accepted, Cotabby can briefly retain Tab ownership while the next continuation regenerates.
PostExhaustionAcceptanceState collapses rapid presses to one queued accept and uses a generation-keyed
timeout so a stale callback cannot release a newer window. Teardown or timeout always returns Tab to
the host.

**Source trail**

- [InputMonitor.swift](../../Cotabby/Services/Input/InputMonitor.swift)
- [SuggestionCoordinator+Acceptance.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator+Acceptance.swift)
- [PostExhaustionAcceptanceState.swift](../../Cotabby/Support/Suggestion/PostExhaustionAcceptanceState.swift)

### 18. How do you insert text into arbitrary applications?

**Strong answer**

For the common short single-line case, Cotabby posts a Unicode CGEvent pair. It is app-agnostic and
does not touch the clipboard. A composing IME uses paste because a synthetic Unicode event can be
absorbed into composition. An optional strategy also pastes long or multiline chunks.

The paste path snapshots all pasteboard representations, places the completion temporarily, tries the
target app's AX Edit > Paste menu item, falls back to Command-V, and restores the clipboard only if no
newer clipboard activity occurred.

There is no perfect universal insertion API. The architecture makes strategy and failure explicit,
then reconciles the host's later AX state.

**Source trail**

- [SuggestionInserter.swift](../../Cotabby/Services/Suggestion/SuggestionInserter.swift)
- [InsertionStrategySelector.swift](../../Cotabby/Support/Suggestion/InsertionStrategySelector.swift)
- [KeyboardInputSourceMonitor.swift](../../Cotabby/Services/Input/KeyboardInputSourceMonitor.swift)

### 19. Why does Chrome need an AX Paste menu action?

**Strong answer**

A synthetic Command-V posted from inside a global tap callback can be ignored in Chrome while the
physical acceptance key is still down. Pressing the application's real Paste menu item drives the
same command through its own command routing and is more reliable. Cotabby caches the menu item per
process but validates every AXPress result; failure falls back to Command-V.

This is a targeted compatibility workaround behind SuggestionInserter rather than a browser branch in
the coordinator.

**Source trail**

- [SuggestionInserter.swift](../../Cotabby/Services/Suggestion/SuggestionInserter.swift)
- [AXHelper.swift](../../Cotabby/Support/Accessibility/AXHelper.swift)

### 20. How do you prevent synthetic insertion from triggering Cotabby again?

**Strong answer**

SuggestionInserter tags every synthetic event with a Cotabby-specific source marker and registers a
bounded expected event burst in InputSuppressionController. InputMonitor checks the marker first and
uses the count as a compatibility fallback when event transformation loses properties.

The count accumulates across rapid acceptances because event delivery is asynchronous. It also
expires, so it cannot become a broad period during which real user input is ignored.

**Source trail**

- [InputSuppressionController.swift](../../Cotabby/Services/Input/InputSuppressionController.swift)
- [InputMonitor.swift](../../Cotabby/Services/Input/InputMonitor.swift)
- [SuggestionInserter.swift](../../Cotabby/Services/Suggestion/SuggestionInserter.swift)

## Inference and Prompting

### 21. Why support three generation backends behind one router?

**Strong answer**

The product needs one suggestion contract while devices and user privacy/performance choices differ.
Apple Intelligence is integrated with the OS, the in-process llama path works with downloaded base
GGUFs, and the OpenAI-compatible path supports loopback Ollama, LAN, or public HTTPS servers.

SuggestionEngineRouter centralizes selection, metrics, prewarm forwarding, reset, and the narrow Apple
unsupported-language fallback. Backend implementations retain their own prompt, stream, lifecycle,
and transport mechanics.

The tradeoff is a larger test matrix. The benefit is that coordinator and session logic do not fork
per backend.

**Source trail**

- [SuggestionEngineRouter.swift](../../Cotabby/Services/Runtime/SuggestionEngineRouter.swift)
- [SuggestionSubsystemContracts.swift](../../Cotabby/Models/Suggestion/SuggestionSubsystemContracts.swift)

### 22. Why does Apple use a different prompt renderer from llama?

**Strong answer**

The llama models are base completion models. They condition on a text sequence; wrapping them in an
instruction conversation wastes tokens and can produce scaffolding instead of a continuation.
BaseCompletionPromptRenderer budgets optional context and places the caret prefix last.

Apple's Foundation Models API provides a first-class instructions channel. FoundationModelPromptRenderer
uses that channel for policy and keeps content in the prompt. The domain request is shared, but the
backend-appropriate representation differs.

**Source trail**

- [BaseCompletionPromptRenderer.swift](../../Cotabby/Support/Prompting/BaseCompletionPromptRenderer.swift)
- [FoundationModelPromptRenderer.swift](../../Cotabby/Support/Prompting/FoundationModelPromptRenderer.swift)
- [SuggestionRequestFactory.swift](../../Cotabby/Support/Suggestion/SuggestionRequestFactory.swift)

### 23. Why are LlamaRuntimeManager and LlamaRuntimeCore separate?

**Strong answer**

LlamaRuntimeManager is MainActor and ObservableObject because Settings and app lifecycle need
published model/loading/error state. LlamaRuntimeCore owns mutable native pointers, tokenization,
prompt sequence reuse, decode, abort, and shutdown. Those operations must not block UI and must obey
native serialization rules.

The core is a nonisolated class marked unchecked Sendable with explicit locks and a lifecycle
condition. That is intentional: Sendable does not make native pointers thread-safe; the implementation
must enforce the synchronization.

The split lets the manager express product state while the core protects native correctness.

**Source trail**

- [LlamaRuntimeManager.swift](../../Cotabby/Services/Runtime/LlamaRuntimeManager.swift)
- [LlamaRuntimeCore.swift](../../Cotabby/Services/Runtime/LlamaRuntimeCore.swift)

### 24. Why not make LlamaRuntimeCore a Swift actor?

**Strong answer**

An actor would serialize Swift entry points, but the runtime also needs synchronous abort/shutdown
coordination, condition waiting around active native operations, and a narrow lock specifically
around prompt-cache/decode state. Native callbacks and C++ lifetime do not automatically become safe
because their wrapper is an actor.

The explicit locks make the required critical sections and shutdown protocol visible. The tradeoff is
manual synchronization and unchecked Sendable responsibility. An actor could be a valid redesign,
but only if it preserved abort and bounded shutdown without blocking an executor or leaking pointers
across isolation.

**Source trail**

- [LlamaRuntimeCore.swift](../../Cotabby/Services/Runtime/LlamaRuntimeCore.swift)
- [LlamaRuntimeManager.swift](../../Cotabby/Services/Runtime/LlamaRuntimeManager.swift)

### 25. How does prompt/KV-cache reuse remain safe?

**Strong answer**

The core tokenizes the new prompt, finds the longest safe reusable prefix against the prepared
sequence, reuses compatible evaluated tokens, and prefills the remainder. The autocomplete lock
serializes that cache state. Field/session changes broadcast reset, model changes rebuild native
state, and incompatible prompts fall back to a fresh sequence.

The key rule is that cache reuse is an optimization under explicit continuity, never hidden
cross-field memory. If continuity is uncertain, correctness wins over latency.

**Source trail**

- [LlamaRuntimeCore.swift](../../Cotabby/Services/Runtime/LlamaRuntimeCore.swift)
- [LlamaSuggestionEngine.swift](../../Cotabby/Services/Runtime/LlamaSuggestionEngine.swift)
- [SuggestionCoordinator+Prediction.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator+Prediction.swift)

### 26. Why normalize output outside each engine?

**Strong answer**

Every backend can emit control tokens, echoed prompt material, reasoning scaffolding, whitespace
seams, duplicated trailing text, or empty/unsafe output. If each engine cleans independently, users
get different acceptance semantics and fixes drift.

SuggestionTextNormalizer provides one backend-independent contract. Engine-specific adapters produce
raw text and metadata; normalization and seam guards decide what can become ghost text.

The tradeoff is that the shared normalizer must not accidentally encode quirks so narrowly that it
damages another backend. Detailed suppression reasons and tests help keep that visible.

**Source trail**

- [SuggestionTextNormalizer.swift](../../Cotabby/Support/Suggestion/SuggestionTextNormalizer.swift)
- [CompletionSeamGuard.swift](../../Cotabby/Support/Suggestion/CompletionSeamGuard.swift)
- [LlamaSuggestionEngine.swift](../../Cotabby/Services/Runtime/LlamaSuggestionEngine.swift)
- [FoundationModelSuggestionEngine.swift](../../Cotabby/Services/Runtime/FoundationModelSuggestionEngine.swift)

## Context and Privacy

### 27. What data does Cotabby use, and when can it leave the Mac?

**Strong answer**

A request can contain bounded text before and after the caret, app/window/domain/placeholder surface
metadata, user rules and extended context, a relevance-filtered clipboard excerpt, and cleaned
screenshot OCR when enabled and permitted.

Apple Intelligence and the in-process llama engine generate on the Mac. The endpoint engine sends the
bounded constructed request to the configured server. Loopback stays on the machine, LAN leaves the
process/machine boundary to a local server, and public HTTPS leaves the local network. Credentials are
stored in Keychain, and insecure public HTTP is rejected.

Debug mode is a separate privacy boundary because it can write full prompts, completions, AX dumps,
and screenshot/OCR artifacts locally.

**Source trail**

- [SuggestionRequestFactory.swift](../../Cotabby/Support/Suggestion/SuggestionRequestFactory.swift)
- [OpenAICompatibleEndpointModels.swift](../../Cotabby/Models/Runtime/OpenAICompatibleEndpointModels.swift)
- [CotabbyDebugOptions.swift](../../Cotabby/Support/Logging/CotabbyDebugOptions.swift)
- [Context, Privacy, and Permissions](../architecture/context-privacy-and-permissions.md)

### 28. How does visual context work, and why not summarize OCR with another model?

**Strong answer**

VisualContextCoordinator owns one field-scoped session. WindowScreenshotService captures a compact
ScreenCaptureKit region, ScreenTextExtractor runs Vision OCR with per-line confidence, OCRTextHygiene
removes corruption and UI chrome, and ScreenshotContextGenerator sanitizes and caps the excerpt.

There is no model summarization stage. A second generation adds latency, can hallucinate, complicates
privacy, and can destroy literal context a base completion model could condition on directly. The
tradeoff is that deterministic hygiene must handle OCR noise well.

**Source trail**

- [VisualContextCoordinator.swift](../../Cotabby/Services/Visual/VisualContextCoordinator.swift)
- [WindowScreenshotService.swift](../../Cotabby/Services/Visual/WindowScreenshotService.swift)
- [ScreenTextExtractor.swift](../../Cotabby/Services/Visual/ScreenTextExtractor.swift)
- [OCRTextHygiene.swift](../../Cotabby/Support/Context/OCRTextHygiene.swift)
- [ScreenshotContextGenerator.swift](../../Cotabby/Services/Visual/ScreenshotContextGenerator.swift)

### 29. Are secure fields never captured?

**Strong answer**

No. The accurate current guarantee is narrower: secure fields are marked blocked, so they cannot
schedule generation, display a suggestion, accept text, or open emoji/macro capture. Their context
cannot reach a generation engine.

However, FocusSnapshotResolver currently constructs a bounded FocusedInputSnapshot before returning
blocked capability, and visual-capture eligibility deliberately ignores capability, including secure
fields. With Screen Recording and visual context enabled, screenshot/OCR can run; explicit debug mode
can persist that capture.

I would call that privacy debt rather than defend it. To reach a true no-capture guarantee, I would
move secure detection ahead of value/context construction and make visual eligibility reject secure
capability, then add tests proving no AX text, screenshot, OCR, or debug artifact is produced.

**Source trail**

- [FocusSnapshotResolver.swift](../../Cotabby/Services/Focus/FocusSnapshotResolver.swift)
- [SuggestionAvailabilityEvaluator.swift](../../Cotabby/Support/Suggestion/SuggestionAvailabilityEvaluator.swift)
- [VisualContextCoordinator.swift](../../Cotabby/Services/Visual/VisualContextCoordinator.swift)

**Why this answer matters**

An honest precise limitation demonstrates more trustworthiness than repeating an outdated privacy
claim.

## Presentation and Product Decisions

### 30. Why use AppKit panels instead of pure SwiftUI?

**Strong answer**

Cotabby needs a borderless panel above another app, on every Space and full-screen environment,
without becoming key, accepting mouse events, entering the window cycle, or stealing editor focus.
Those are NSPanel and NSWindow behaviors.

OverlayController owns the panel and hosts typed SwiftUI content for the ghost or mirror view. This
uses SwiftUI where it is strong and AppKit for window semantics. The tradeoff is bridging two UI
systems, but a pure SwiftUI scene does not provide the required cross-application panel control.

**Source trail**

- [OverlayController.swift](../../Cotabby/Services/Presentation/OverlayController.swift)
- [SuggestionOverlayPresenter.swift](../../Cotabby/Services/Suggestion/SuggestionOverlayPresenter.swift)

### 31. Why have emoji and macros inside an autocomplete app?

**Strong answer**

They reuse the same cross-application focus and insertion infrastructure but are deterministic,
low-latency productivity features. They do not call the model. Pure trigger state machines decide
whether colon or slash capture is active, and InlineCommandCoordinator arbitrates the one consuming
input slot.

Architecturally, they demonstrate why InputMonitor should expose semantic capture ownership rather
than hard-code suggestion logic. The risk is feature interference, so their sigils are disjoint,
capture is pinned to one focus sequence, and the suggestion coordinator stands down when either
feature owns the event.

**Source trail**

- [InlineCommandCoordinator.swift](../../Cotabby/App/Coordinators/InlineCommandCoordinator.swift)
- [EmojiPickerController.swift](../../Cotabby/App/Coordinators/EmojiPickerController.swift)
- [MacroController.swift](../../Cotabby/App/Coordinators/MacroController.swift)
- [EmojiTriggerStateMachine.swift](../../Cotabby/Support/Emoji/EmojiTriggerStateMachine.swift)
- [MacroTriggerStateMachine.swift](../../Cotabby/Support/Macros/MacroTriggerStateMachine.swift)

## Testing, Critique, and Engineering Judgment

### 32. How do you test a system that depends on global macOS behavior?

**Strong answer**

I separate deterministic policy from OS boundaries. Work identity, request construction,
normalization, session reconciliation, trigger machines, geometry policy, prompt rendering, and
insertion planning have unit-testable value inputs. Coordinators depend on narrow protocols and fakes.

Real AX, event taps, host publication, IMEs, browser behavior, signing, and TCC still require
integration/manual compatibility testing. Unit tests reduce the state-space before that matrix; they
do not pretend to replace it.

CI independently checks compilation, tests, SwiftLint, and XcodeGen synchronization.

**Source trail**

- [CotabbyTests](../../CotabbyTests)
- [SuggestionSubsystemContracts.swift](../../Cotabby/Models/Suggestion/SuggestionSubsystemContracts.swift)
- [tests workflow](../../.github/workflows/tests.yml)
- [XcodeGen workflow](../../.github/workflows/xcodegen.yml)

### 33. What are the biggest pieces of technical debt?

**Strong answer**

I would name debt precisely:

1. Secure-field acquisition is broader than the privacy promise we want.
2. SuggestionCoordinator remains complex even after extracting pure rules and state owners.
3. Accessibility compatibility contains necessary app-specific branches that need a documented
   compatibility matrix and regression harness.
4. Unit coverage is strong, but a repeatable end-to-end host compatibility harness is still the next
   step for proving AX, input, presentation, and insertion together.
5. Endpoint support expands the privacy and availability matrix beyond the original on-device story.

I would not propose a rewrite. I would first fix privacy-boundary tests and documentation, strengthen
integration replay/compatibility coverage, and continue extracting cohesive policy from the
coordinator only when ownership becomes clearer.

**Source trail**

- [SuggestionAvailabilityEvaluator.swift](../../Cotabby/Support/Suggestion/SuggestionAvailabilityEvaluator.swift)
- [SuggestionCoordinator.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator.swift)
- [FocusSnapshotResolver.swift](../../Cotabby/Services/Focus/FocusSnapshotResolver.swift)
- [SuggestionStreamingState.swift](../../Cotabby/Support/Suggestion/SuggestionStreamingState.swift)
- [PostExhaustionAcceptanceState.swift](../../Cotabby/Support/Suggestion/PostExhaustionAcceptanceState.swift)

### 34. What would you do differently if you started Cotabby again?

**Strong answer**

I would define the interaction session and reliability invariants earlier: focus identity,
request/work identity, overlay/session equality, fail-open input, and post-insertion verification. I
would also establish an application compatibility matrix and correlated structured logging before
adding many app-specific fallbacks.

I would keep the same broad boundaries—one dependency graph, normalized focus model, pure rules,
backend router, native core, and AppKit panel ownership—but make privacy acquisition gates and test
seams first-class from the first version.

The useful lesson is not that the current code is wrong; it is that the difficult state-machine
properties became visible through real host applications and should be explicit earlier in the next
product.

### 35. How do you know Cotabby is reliable?

**Strong answer**

Reliability is not one metric. I would separate:

- Input integrity: no non-owned key is swallowed
- Freshness: no result applies to the wrong focus or text
- Insertion correctness: accepted text matches the planned mutation
- Presentation correctness: visible text matches session state and is anchored safely
- Availability: permissions and selected runtime degrade explicitly
- Latency: time to first useful partial and final result
- Resource behavior: idle AX cost, memory, model switch cleanup, shutdown
- Privacy: context acquisition, persistence, and transport match disclosure

Cotabby has explicit guards and structured request-correlated logs for these, plus unit tests around
pure invariants. The next maturity step is a formal compatibility matrix and repeatable end-to-end
host harness that reports these dimensions per application.

**Source trail**

- [RequestID.swift](../../Cotabby/Support/Logging/RequestID.swift)
- [SuggestionDebugLogger.swift](../../Cotabby/Services/Suggestion/SuggestionDebugLogger.swift)
- [SuggestionSessionReconciler.swift](../../Cotabby/Support/Suggestion/SuggestionSessionReconciler.swift)
- [InputMonitor.swift](../../Cotabby/Services/Input/InputMonitor.swift)

## HyperWrite Scoping Questions

### 36. How would you approach turning the HyperWrite Mac prototype into a reliable alpha?

**Strong answer**

I would begin by observing the current prototype and defining its core interaction contract before
rewriting anything. For each suggestion I need to know:

- What focused editor state is considered authoritative?
- What makes a request current or stale?
- Which component owns the active suggestion?
- Which keys may be consumed, and under what success condition?
- How is accepted text inserted and verified?
- What are the supported applications and explicit degradation modes?
- What context leaves the machine?
- Which correlated events let us explain a failure?

I would instrument that loop first, then harden focus/input/insertion and stale-work invariants,
because model quality cannot compensate for dropped keys or text inserted into the wrong field. I
would preserve working prototype components behind narrow interfaces and replace only boundaries
whose failure data justifies it.

The alpha should have a declared compatibility matrix and measurable gates for input integrity,
stale-result rejection, insertion success, crash-free operation, latency, memory, and privacy—not a
claim that every macOS text field works.

**Further preparation**

- [HyperWrite Reliability Translation](hyperwrite-reliability-translation.md)

### 37. Would you copy Cotabby's architecture into HyperWrite?

**Strong answer**

I would transfer invariants, not copy the repository. The reusable ideas are one ownership graph,
normalized focus state, explicit work identity, a real interaction session, fail-open input,
strategy-based insertion, backend-independent normalization, geometry-quality-aware presentation,
bounded context, and request-correlated observability.

I would not automatically copy polling cadence, app-specific AX fallbacks, local llama lifecycle,
prompt format, settings complexity, or the current coordinator shape. Those depend on HyperWrite's
prototype, backend, product promise, and supported application set.

The first technical session should determine which failure modes are actually present.

### 38. What would you prioritize if the trial is constrained?

**Strong answer**

I would prioritize the smallest loop that users can trust:

1. Reliable focused-editor snapshot in the agreed application set
2. Fail-open input handling
3. Stale-request cancellation and identity
4. One validated generation path
5. Overlay/session consistency
6. Verified insertion, including IME policy
7. Correlated observability and repeatable compatibility tests
8. Permission/onboarding and distributable signing

I would defer broad app claims, multiple speculative backends, elaborate settings, and optional
context until the core loop has measured reliability. That sequencing creates an alpha we can learn
from rather than a wide demo with unexplained failures.

## Rapid-Fire Follow-Ups

Use these to test whether you understand the answers rather than memorizing them:

- What exact state invalidates one suggestion?
- What is the narrowest possible stale-result check, and why is it insufficient alone?
- Which code can legally return nil from a CGEvent tap?
- What happens when the visible overlay and session tail disagree?
- Which cache is allowed to survive ordinary typing?
- Which cache must reset on a field switch?
- What is the difference between local process, local machine, LAN, and public endpoint privacy?
- Which synchronous operation is most likely to hurt typing latency?
- Which native object is least safe to move across isolation?
- What proves that an insertion succeeded?
- Which bug would request_id let you diagnose that a plain error string would not?
- Which current product statement would you correct before a public endpoint launch?

If you cannot answer a follow-up with a file and an invariant, return to the corresponding mastery
area in [the study path](README.md).
