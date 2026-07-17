# Cotabby Architecture

This is the ten-minute maintainer map for Cotabby. It explains the product loop, ownership
boundaries, reliability rules, and the best files to read before changing behavior. It is intentionally
a roadmap rather than an encyclopedia.

## What Cotabby Is

Cotabby is a macOS menu bar agent that provides inline autocomplete in other applications:

1. Find the focused editable field through macOS Accessibility.
2. Observe global keyboard input without taking focus.
3. Gate work using permissions, field capability, settings, and runtime state.
4. Build a bounded request from caret text and optional context.
5. Generate through Apple Intelligence, an in-process llama.cpp model, or a user-configured
   OpenAI-compatible endpoint.
6. Normalize the result into a safe short continuation.
7. Render inline ghost text or a mirror card near the caret.
8. Reconcile typing against the active suggestion and insert accepted chunks through configurable
   shortcuts.

The product is local-first, not unconditionally offline. Apple Intelligence and the bundled
open-source path run on the Mac. An endpoint can be loopback, on the local network, or a public HTTPS
service; when selected, the bounded request is sent to that server.

## Architectural Constraints

These rules explain most of the structure:

- There is one app-lifetime dependency graph. Views never create process-wide services.
- Accessibility state is eventually consistent and app-specific. Every async result can be stale.
- Generation, presentation, and insertion fail closed for secure and unsupported fields. Early
  acquisition has a current secure-field caveat described under privacy below.
- User text and optional context are bounded before generation.
- On-device work stays local unless the user explicitly selects an endpoint engine.
- Global input is observed in a fail-open way; Cotabby consumes only events it successfully handles.
- MainActor owns UI, published state, AppKit, and most AX access. OCR, downloads, and generation do
  not block it.
- Mutable native llama state is explicitly serialized and released before process teardown.
- Pure policy belongs outside coordinators so the state machine remains testable.

## Repository Map

- [Cotabby/App](Cotabby/App): application entry point, composition root, lifecycle, and coordinators.
- [Cotabby/UI](Cotabby/UI): SwiftUI and AppKit-facing presentation for settings, onboarding, menus,
  previews, and user surfaces.
- [Cotabby/Services](Cotabby/Services): side-effectful boundaries for AX, event taps, insertion,
  capture/OCR, generation, downloads, permissions, updates, and AppKit panels.
- [Cotabby/Models](Cotabby/Models): shared values, settings, states, configuration, and protocol
  contracts.
- [Cotabby/Support](Cotabby/Support): deterministic rules, prompt rendering, normalization,
  reconciliation, layout, and low-level bridging helpers.
- [CotabbyTests](CotabbyTests): unit tests and microbenchmarks, with emphasis on pure Support and
  Models behavior.
- CotabbyInference: the llama.cpp Swift wrapper consumed from an external SwiftPM package pinned to
  its main branch; native code is not vendored here.

Folder names describe the dominant responsibility, not the UI framework. Cotabby/UI contains
SwiftUI views, while AppKit panel/window controllers live mostly under Cotabby/Services/UI or app
coordinators because they own process-level presentation behavior.

## End-to-End Data Flow

~~~text
CGEvent and focus poll
  -> FocusTracker
  -> FocusSnapshotResolver + AXTextGeometryResolver
  -> FocusSnapshot
  -> SuggestionCoordinator
       -> availability and native correction
       -> debounce + current work identity
       -> SuggestionRequestFactory
            -> bounded AX / surface / clipboard / visual / user context
       -> SuggestionEngineRouter
            -> Apple | in-process llama | OpenAI-compatible endpoint
       -> SuggestionTextNormalizer + seam guards
       -> SuggestionInteractionState
       -> SuggestionOverlayPresenter -> OverlayController
  -> typing reconciliation or configured acceptance
  -> SuggestionInserter
  -> host AX publication check and next prediction
~~~

The request is immutable after generation begins. Engines do not reach back into live AX state.
Before a partial, final, or insertion applies, the coordinator verifies current work identity, focus,
content signatures, settings continuity, and session state.

## Lifecycle and Ownership

Read these first:

1. [CotabbyApp.swift](Cotabby/App/Core/CotabbyApp.swift)
2. [AppDelegate.swift](Cotabby/App/Core/AppDelegate.swift)
3. [CotabbyAppEnvironment.swift](Cotabby/App/Core/CotabbyAppEnvironment.swift)

| Owner | Responsibility | Lifetime |
| --- | --- | --- |
| CotabbyApp | SwiftUI scenes, MenuBarExtra, AppDelegate bridge | Process |
| CotabbyAppEnvironment | Construct the shared object graph and retain graph-internal subscriptions | Process |
| AppDelegate | Start/stop services and retain lifecycle-driven subscriptions | Process |
| Coordinators | Orchestrate one product surface across services | App or window |
| Services | Own one side effect, OS boundary, or mutable subsystem | Injected |
| Views | Render shared state and send narrow user intents | SwiftUI/AppKit surface |

AppDelegate starts the selected runtime, focus polling, input monitoring, updates, suggestion
coordination, inline commands, and onboarding after launch. It stops new work before tearing down
global taps, polling, and native resources at termination. Production service startup is skipped in
the XCTest host.

CotabbyAppEnvironment also owns important subscriptions: focus cadence, global-toggle tap binding,
power-profile application, engine/model selection, and endpoint connection invalidation. AppDelegate
owns permission reactions, engine runtime start/stop, overlays, model-directory refresh, and
process-lifecycle behavior. Both retain subscriptions because both own different relationships.

[SuggestionSettingsModel.swift](Cotabby/Models/SuggestionSettingsModel.swift) is the published source
of app behavior. [SuggestionSettingsStore.swift](Cotabby/Support/SuggestionSettingsStore.swift)
persists non-secret preferences in UserDefaults. Endpoint credentials live in Keychain.

## Suggestion State Machine

Read the coordinator in this order:

1. [SuggestionCoordinator.swift](Cotabby/App/Coordinators/SuggestionCoordinator.swift)
2. [SuggestionCoordinator+Lifecycle.swift](Cotabby/App/Coordinators/SuggestionCoordinator+Lifecycle.swift)
3. [SuggestionCoordinator+Input.swift](Cotabby/App/Coordinators/SuggestionCoordinator+Input.swift)
4. [SuggestionCoordinator+Prediction.swift](Cotabby/App/Coordinators/SuggestionCoordinator+Prediction.swift)
5. [SuggestionCoordinator+Acceptance.swift](Cotabby/App/Coordinators/SuggestionCoordinator+Acceptance.swift)

The coordinator owns orchestration and user-facing suggestion state. It delegates rules and mutable
sub-state to smaller boundaries:

- [SuggestionAvailabilityEvaluator.swift](Cotabby/Support/SuggestionAvailabilityEvaluator.swift):
  pure permission, settings, focus, and runtime gates.
- [SuggestionRequestFactory.swift](Cotabby/Support/SuggestionRequestFactory.swift): pure bounded
  request construction and prompt preview.
- [SuggestionWorkController.swift](Cotabby/Services/Suggestion/SuggestionWorkController.swift):
  debounce/generation tasks and monotonically increasing work IDs.
- [SuggestionInteractionState.swift](Cotabby/Services/Suggestion/SuggestionInteractionState.swift):
  active session, materialized context, consumed prefix, and known post-insertion AX lag.
- [SuggestionSessionReconciler.swift](Cotabby/Support/SuggestionSessionReconciler.swift): type-through,
  acceptance, and live-host reconciliation.
- [SuggestionTextNormalizer.swift](Cotabby/Support/SuggestionTextNormalizer.swift): backend-independent
  cleanup, echo removal, whitespace policy, trailing-text deduplication, and unsafe-output rejection.

A native correction path runs before model generation. NSSpellChecker and bundled SymSpell indexes
can suppress completion while a likely typo is forming, offer a green atomic replacement, or apply
an opt-in automatic fix after Space.

Engines can stream cumulative partials. The coordinator coalesces UI work, accepts only monotonic
extensions, and allows a displayed partial to become an active accept-ready session. The final result
remains authoritative and can replace or suppress provisional text.

Normal sessions support exact type-through, word or phrase acceptance, full-tail acceptance, CJK-aware
segmentation, punctuation handling, optional trailing space, and speculative generation after final
acceptance. Corrections commit atomically rather than exposing partial acceptance.

## Focus and Accessibility

Read:

1. [FocusTracker.swift](Cotabby/Services/Focus/FocusTracker.swift)
2. [FocusSnapshotResolver.swift](Cotabby/Services/Focus/FocusSnapshotResolver.swift)
3. [FocusModels.swift](Cotabby/Models/FocusModels.swift)
4. [AXTextGeometryResolver.swift](Cotabby/Services/Focus/AXTextGeometryResolver.swift)
5. [AXHelper.swift](Cotabby/Support/AXHelper.swift)

FocusTracker uses timer polling as the authoritative source because AX notifications are inconsistent
across AppKit, browsers, Electron, and custom editors. Activity resets the cadence; idle unchanged
state backs it off. Input and acceptance paths may request an explicit fresh capture, but do not trust
event payloads as complete field state.

FocusSnapshotResolver finds a usable editable candidate, blocks secure/unsupported surfaces, bounds
text on both sides of the caret, resolves the focused process, and publishes stable domain values.
Chromium/Electron require accessibility priming, cursor hit-test recovery, and out-of-process iframe
handling. All fallbacks are revalidated and yield to a valid system-focused element.

AXTextGeometryResolver tries direct range bounds, browser text-marker bounds, a nearby measured
character, child static-text runs, and field-frame estimation. Geometry is labeled exact, derived,
estimated, or layoutEstimated; presentation uses that quality rather than pretending every rectangle
is equally trustworthy.

AX is synchronous cross-process IPC on MainActor. Deep walks are gated, cached, bounded, and
throttled. Calendar has a narrow capture guard because enumerating its transient editor can dismiss
the editor. Async consumers carry focus/content signatures instead of relying on AX element identity
alone.

## Global Input and Insertion

[InputMonitor.swift](Cotabby/Services/Input/InputMonitor.swift) owns three event-tap responsibilities:

- A steady listen-only observer for typing, deletion, navigation, and pointer activity.
- A conditional consuming tap while a suggestion or inline-command capture needs interception.
- A separate consuming tap for the configured global-toggle shortcut.

The conditional tap consumes a matching key only after the owning coordinator succeeds. Stale taps,
missing overlays, rejected sessions, and revoked permission fail open so the host receives the key.
Word/phrase and full-tail acceptance have independent configurable key/modifier bindings.

[InputSuppressionController.swift](Cotabby/Services/Input/InputSuppressionController.swift) marks and
counts Cotabby-generated events so insertion does not re-enter the typing pipeline.

[SuggestionInserter.swift](Cotabby/Services/Suggestion/SuggestionInserter.swift) normally posts short
Unicode key events without touching the clipboard. Active IME composition uses a clipboard paste
commit. A default-off policy can also paste long or multiline chunks. Paste tries the target app's
Accessibility Paste menu item before synthetic Command-V and restores every pasteboard representation
unless newer user clipboard activity wins.

Replacement sessions delete their validated literal run before inserting correction, emoji, or macro
text. Posting events is not treated as proof of success; the later AX snapshot is reconciled.

## Engines and Prompting

[SuggestionEngineRouter.swift](Cotabby/Services/Runtime/SuggestionEngineRouter.swift) selects one of:

- [FoundationModelSuggestionEngine.swift](Cotabby/Services/Runtime/FoundationModelSuggestionEngine.swift)
  for Apple Intelligence. It uses the framework's instructions channel, streams cumulative partials,
  and keeps a one-use compatible prewarmed session. Unsupported language/locale can fall back to llama.
- [LlamaSuggestionEngine.swift](Cotabby/Services/Runtime/LlamaSuggestionEngine.swift) for an in-process
  GGUF base model through CotabbyInference. [LlamaRuntimeManager.swift](Cotabby/Services/Runtime/LlamaRuntimeManager.swift)
  publishes state; [LlamaRuntimeCore.swift](Cotabby/Services/Runtime/LlamaRuntimeCore.swift) owns native
  pointers, tokenization, KV-cache reuse, prefill, sampling, abort, and shutdown.
- [OpenAICompatibleSuggestionEngine.swift](Cotabby/Services/Runtime/OpenAICompatibleSuggestionEngine.swift)
  for completion/chat APIs and SSE streams. The default is loopback Ollama at
  http://127.0.0.1:11434/v1; LAN and public HTTPS endpoints are supported, while insecure public HTTP
  is rejected.

LlamaRuntimeCore is a nonisolated lock/condition-protected native boundary, not a Swift actor. Its
autocomplete lock serializes cache/decode state, and its lifecycle condition prevents shutdown from
racing active native work. Heavy work runs away from MainActor.

[BaseCompletionPromptRenderer.swift](Cotabby/Support/BaseCompletionPromptRenderer.swift) renders a
base-model text continuation with optional budgeted context and the caret prefix last. It does not
wrap a base GGUF in an instruction conversation. [FoundationModelPromptRenderer.swift](Cotabby/Support/FoundationModelPromptRenderer.swift)
keeps Apple's instruction-shaped prompt separate.

Prewarm is opportunistic and goes only to the selected backend. Context reset reaches every backend.
The local runtime is loaded only for the Open Source engine and is released when switching to Apple
or endpoint mode so mapped weights and Metal buffers do not stay resident unnecessarily.

## Context, Privacy, and Permissions

[PermissionManager.swift](Cotabby/Services/Permission/PermissionManager.swift) tracks:

- Accessibility: required for focus, text, capability, geometry, and insertion validation.
- Input Monitoring: required for global keyboard observation and acceptance interception.
- Screen Recording: optional, used only for screenshot-derived context.

Context sources are independently enabled and bounded: recent AX prefix/trailing text, surface
metadata, user rules/extended context, relevant clipboard content, visual OCR, language, and settings.
[PromptContextSanitizer.swift](Cotabby/Support/PromptContextSanitizer.swift) sanitizes optional text,
and prompt renderers apply per-section budgets.

[ClipboardContextProvider.swift](Cotabby/Services/Utilities/ClipboardContextProvider.swift) reads a
fresh bounded value at request time rather than recording clipboard history. Relevance and distillation
policies drop unrelated or excessive content.

Visual context is one field-scoped session:

~~~text
VisualContextCoordinator
  -> WindowScreenshotService (ScreenCaptureKit crop)
  -> ScreenTextExtractor (Vision OCR + line confidence)
  -> OCRTextHygiene
  -> bounded sanitized excerpt
~~~

There is no model summarization step and raw screenshots do not enter prompts. Missing Screen Recording
produces an explicit unavailable state without disabling text-only autocomplete. Debug screenshot/OCR
artifacts exist only under the explicit debug launch mode.

Secure fields cannot schedule generation, show a suggestion, accept text, or open an inline command,
so their context cannot flow into an engine request. The acquisition boundary is currently broader
than that guarantee: FocusSnapshotResolver still creates a bounded context for a secure field before
marking its capability blocked, and visual-capture eligibility deliberately ignores capability so
screenshot/OCR can warm for that field. The excerpt cannot be consumed by prediction, but explicit
debug mode can persist visual captures. Treat this as privacy debt; current architecture guarantees
no secure-field generation, not no secure-field acquisition.

Endpoint credentials are stored in Keychain. A remote endpoint receives the same bounded request that
would otherwise be used locally, so its privacy scope must remain visible in settings and
documentation.

## Presentation and Sibling Features

[SuggestionOverlayPresenter.swift](Cotabby/Services/Suggestion/SuggestionOverlayPresenter.swift)
decides presentation actions. [OverlayController.swift](Cotabby/Services/UI/OverlayController.swift)
owns a reusable borderless non-activating NSPanel and SwiftUI-hosted content.

Automatic presentation uses inline ghost text for exact/derived caret geometry and a mirror card for
estimated/layout-estimated geometry, mid-line editing, or explicit user preference. The overlay can
match host font/color, render corrections distinctly, respect right-to-left and multiline layout,
show an acceptance hint, and advance a partial tail without waiting for noisy AX geometry.

[ActivationIndicatorController.swift](Cotabby/Services/UI/ActivationIndicatorController.swift) owns
the optional field/caret indicator. [FocusDebugOverlayController.swift](Cotabby/Services/UI/FocusDebugOverlayController.swift)
is developer-only and gated by -cotabby-debug.

[InlineCommandCoordinator.swift](Cotabby/App/Coordinators/InlineCommandCoordinator.swift) arbitrates
the single input-capture slot between:

- [EmojiPickerController.swift](Cotabby/App/Coordinators/EmojiPickerController.swift): colon query,
  lazy catalog/matcher, non-activating picker, recency/frequency ranking, and literal-run replacement.
- [MacroController.swift](Cotabby/App/Coordinators/MacroController.swift): slash query and deterministic
  date, random, unit, currency, and arithmetic evaluation through MacroEngine.

Both use pure trigger state machines, stay pinned to one supported focus sequence, and cancel on
focus change or incompatible input. They do not call a language model.

[SettingsCoordinator.swift](Cotabby/App/Coordinators/SettingsCoordinator.swift) and
[WelcomeCoordinator.swift](Cotabby/App/Coordinators/WelcomeCoordinator.swift) own app-lifetime AppKit
windows hosting SwiftUI content. Settings and onboarding observe the shared graph. Hiding the menu bar
icon retains a recovery path to Settings.

## Concurrency and Reliability Rules

- Revalidate after every await that can outlive focus, content, settings, or work identity.
- Treat cancellation as expected lifecycle, not automatically as a backend failure.
- Keep AX and AppKit access MainActor-isolated, but bound synchronous AX work aggressively.
- Use actors or explicit serialization for mutable non-UI state; do not move native pointers across
  an ownership boundary casually.
- Never use only AX element identity as a stale-result guard.
- Keep overlay text and active-session remaining text equal before acceptance.
- Preserve the narrow known-insertion sentinel; general stale AX tolerance hides real divergence.
- Stop new generation and input work before releasing runtime state at termination.

## Safe Change Order

When behavior changes, prefer:

1. Pure policy and helpers in Support.
2. Domain values, state, settings, and contracts in Models.
3. Side-effectful boundaries in Services.
4. Orchestration in App.
5. Presentation in UI.

This is a dependency direction, not a demand to touch every layer. A pure rule should not be added to
SuggestionCoordinator just because that is where its symptom becomes visible.

## Debugging and Validation

Development schemes launch with -cotabby-debug. That enables local privacy-sensitive diagnostics in
addition to unified logging:

- ~/Library/Logs/Cotabby/cotabby.jsonl: structured event stream.
- ~/Library/Logs/Cotabby/llm-io.jsonl: full prompt/completion records.
- ~/Desktop/cotabby-ax-dump.txt: most recent Chrome focus AX tree.
- ~/Desktop/cotabby-debug-screenshots/: retained visual-context capture/OCR pairs.

Every prediction carries a request_id through coordinator, router, engine, and LLM-I/O records. Start
with category focus for field/geometry failures, suggestion for state/acceptance failures, runtime for
model failures, and app for permissions/lifecycle.

[project.yml](project.yml) is the Xcode project source of truth. XcodeGen produces the committed
[Cotabby.xcodeproj](Cotabby.xcodeproj); CI regenerates it and fails when the checked-in project differs.
Cotabby and Cotabby Dev build the same sources under distinct bundle/product identities so development
does not overwrite the production app's TCC grants. Swift default actor isolation is MainActor.

Use the narrowest relevant tests first, then broaden. The standard build boundary is:

~~~bash
xcodebuild -project Cotabby.xcodeproj -scheme Cotabby -destination 'platform=macOS' build \
  -derivedDataPath build/DerivedData

xcodebuild -project Cotabby.xcodeproj -scheme Cotabby -destination 'platform=macOS' build-for-testing \
  -derivedDataPath build/DerivedData
~~~

CI independently checks project generation, compilation, tests, and SwiftLint. Pure state machines,
policies, prompt utilities, normalization, and layout logic should receive focused unit coverage.

## Problem-to-File Map

| Symptom or change | Start here |
| --- | --- |
| App startup, duplicate service, shutdown | CotabbyAppEnvironment, AppDelegate |
| Field not detected or wrong app policy | FocusTracker, FocusSnapshotResolver |
| Ghost at wrong location | AXTextGeometryResolver, CompletionRenderModePolicy, OverlayController |
| Suggestion never starts | SuggestionAvailabilityEvaluator, SuggestionCoordinator+Prediction |
| Old suggestion appears | SuggestionWorkController, focus/content signatures |
| Wrong prompt or leaked optional context | SuggestionRequestFactory, prompt renderer, sanitizer |
| Backend selection or memory issue | SuggestionEngineRouter, AppDelegate, LlamaRuntimeManager |
| Native decode/cache/shutdown issue | LlamaRuntimeCore, CotabbyInference boundary |
| Partial/final output mismatch | streaming policy, SuggestionTextNormalizer, seam guards |
| Acceptance key passes through or is stolen | InputMonitor, acceptance validation |
| Wrong or repeated inserted text | SuggestionInserter, InputSuppressionController, reconciler |
| Clipboard context is irrelevant | ClipboardRelevanceFilter, ClipboardContentDistiller |
| Screenshot context is stale/noisy | VisualContextCoordinator, OCRTextHygiene |
| Emoji or macro conflicts with suggestions | InlineCommandCoordinator, feature trigger machine |
| Permission loop or lost grant | PermissionManager, PermissionGuidanceController, app identity |
| Settings/onboarding window issue | SettingsCoordinator, WelcomeCoordinator |

When a change crosses several rows, keep ownership at these boundaries rather than teaching one
coordinator to perform every step itself.
