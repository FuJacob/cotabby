# Suggestion Pipeline

## Purpose

This guide follows one autocomplete attempt from an input event to visible or inserted text. The
pipeline is a state machine operating over eventually consistent Accessibility data. Reliability
comes from explicit work identity, cancellation, focus signatures, session reconciliation, and
safe failure behavior rather than from assuming that events arrive in a convenient order.

## Coordinator Reading Order

Read the coordinator in this order:

1. [SuggestionCoordinator.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator.swift)
2. [SuggestionCoordinator+Lifecycle.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator+Lifecycle.swift)
3. [SuggestionCoordinator+Input.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator+Input.swift)
4. [SuggestionCoordinator+Prediction.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator+Prediction.swift)
5. [SuggestionCoordinator+Acceptance.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator+Acceptance.swift)

The base file declares dependencies and mutable orchestration state. The extensions group lifecycle,
input, prediction, and acceptance behavior without turning those concerns into separate owners.

## End-to-End Flow

~~~text
focus snapshot or input event
  -> availability and session reconciliation
  -> debounce and work identity
  -> refresh AX state if stale
  -> native correction decision
  -> bounded request construction
  -> selected engine generation
  -> streamed partial presentation
  -> authoritative final normalization and guards
  -> active suggestion session
  -> overlay presentation
  -> type-through, dismissal, partial acceptance, or full acceptance
  -> host publish reconciliation and next prediction
~~~

## Starting and Stopping

start installs callbacks on the focus provider, input monitor, permissions, settings, overlay, and
visual-context coordinator. It also snapshots current settings and begins reacting to the current
focus. stop removes or neutralizes those callbacks, cancels all prediction work, clears active
sessions, hides presentation, and resets backend-local generation context.

The coordinator is MainActor-isolated. That makes transitions involving coordinator state, AppKit
presentation, and Accessibility snapshots sequential from the coordinator's perspective. Only
state that UI actually observes remains `@Published`; internal debug/session values are plain
MainActor properties. Heavy backend work is moved off the actor by the backend implementations.

## Focus Changes and Prewarm

A supported focused field creates or refreshes a field-scoped interaction context. Focus changes:

- Cancel obsolete generation work.
- Reset active suggestion and backend continuation state when continuity is broken.
- Start visual-context capture for the new field when enabled and permitted.
- Build a request-shaped warmup payload.
- Prewarm only the selected backend.

Prewarm is opportunistic. Failure to warm never becomes a user-facing prediction failure; it only
means the first real request pays the cold setup cost.

## Input Handling

Inline commands receive first look at captured input. If the emoji or macro feature owns the current
keystroke, normal suggestion behavior stands down and any conflicting ghost text is hidden.

For ordinary input, the coordinator distinguishes:

- Direct text mutation
- Deletion
- Navigation or selection movement
- Escape/dismissal
- Word acceptance
- Full acceptance
- Synthetic events Cotabby generated itself

Direct typing can advance a visible session without regenerating when the typed characters exactly
match the next suggestion tail. Divergent typing invalidates the session and schedules new work.
Navigation, selection, focus changes, or incompatible trailing-text changes clear stale sessions.

## Work Identity and Cancellation

[SuggestionWorkController.swift](../../Cotabby/Services/Suggestion/SuggestionWorkController.swift)
owns the debounce task, generation task, and a monotonically increasing work ID.

Replacing work:

1. Cancels the previous debounce and generation tasks.
2. Advances the work ID.
3. Starts a new debounce operation.
4. Allows generation to apply results only while that ID remains current.

Cancellation alone is insufficient because native or system APIs can finish after Swift cancellation
was requested. Result application therefore also validates work ID, request generation, focus
identity, content signature, settings continuity, and current field state.

## Debounce and AX Publish Timing

A global key event can arrive before the host application publishes its new value through
Accessibility. Reading immediately would build a request from pre-keystroke text. Cotabby combines
debounce with explicit focus refreshes and short host-publish polling when it knows the host is
catching up.

The pipeline has a ceiling: if a host never publishes a detectable change, it eventually proceeds
through normal downstream guards instead of waiting forever. Freshness helpers avoid paying
duplicate synchronous AX walks when another pipeline stage just captured the same state.

## Eligibility

[SuggestionAvailabilityEvaluator.swift](../../Cotabby/Support/Suggestion/SuggestionAvailabilityEvaluator.swift)
contains pure gating rules. A prediction may be withheld because of:

- Missing required permissions
- Global disable or temporary pause
- Per-application disable
- Unsupported or secure focus capability
- Selection or incompatible editing state
- Terminal policy
- Insufficient text signal
- Runtime or engine availability

Gating is repeated at meaningful async boundaries. Passing eligibility before debounce does not
authorize applying a result after the user switches fields, changes settings, or selects text.

## Corrections Before Model Generation

Spelling correction is a native fast path evaluated before model generation. TypoGate determines
whether the current editing shape is eligible. CurrentWordSpellChecker uses NSSpellChecker, while
SymSpellCorrector supplies frequency-ranked multilingual candidates after its index is available.

Depending on settings and the input event, the coordinator can:

- Suppress model completion while the user is still building a likely typo.
- Present a correction as a green replace-the-word suggestion.
- Automatically replace a completed typo after Space.
- Continue to ordinary model generation when no correction applies.

A correction session has different acceptance semantics from a continuation. It commits as one
atomic replacement rather than exposing partial word acceptance.

## Request Construction

[SuggestionRequestFactory.swift](../../Cotabby/Support/Suggestion/SuggestionRequestFactory.swift) builds an
immutable SuggestionRequest and the selected backend's developer-debug prompt payload. It:

- Bounds the prefix according to the selected engine.
- Selects a language-aware prediction budget.
- Adds enabled extended, clipboard, visual, and surface context.
- Sanitizes and budgets optional context.
- Builds the base-model prompt used by llama and completion-style endpoints.
- Preserves structured request fields for the Apple prompt renderer.
- Assigns a request ID used across structured logs.

The coordinator decides when to request. The factory decides what the request contains. Engines do
not reach back into live Accessibility state while generation is running.

## Streaming and Final Results

SuggestionGenerating exposes both a single-result method and a streaming method. Streaming engines
send cumulative, already-normalized partials.
[SuggestionStreamingState.swift](../../Cotabby/Support/Suggestion/SuggestionStreamingState.swift)
owns three pure bookkeeping rules: the newest pending partial wins, only one runloop drain is
scheduled at a time, and rendered text grows monotonically through StreamedGhostTextPolicy. The
coordinator still owns DispatchQueue scheduling, freshness checks, session creation, and overlay
side effects.

A streamed partial can become a real active session, allowing acceptance before decoding finishes.
The final result remains authoritative. It may replace the partial, suppress it, or clear it if final
confidence and seam guards reject the completion.

Streaming presentation is controlled by settings. Backend streaming support does not imply that
partials must always be painted.

## Normalization and Display Guards

SuggestionTextNormalizer applies backend-independent cleanup:

- Removes control tokens and reasoning blocks.
- Strips echoed prompt scaffolding.
- Applies single-line or bounded multi-line policy.
- Rejects duplication of text already after the caret.
- Removes repeated prefix echoes.
- Reconciles leading whitespace.
- Rejects unsafe or empty insertions.

The coordinator then applies display-time checks such as CompletionSeamGuard. That guard suppresses
junk punctuation runs and likely mid-word misspelling splices. Streaming uses the cheap pure part of
the guard; the authoritative final can run the full spelling-dependent verdict.

## Active Sessions

[SuggestionInteractionState.swift](../../Cotabby/Services/Suggestion/SuggestionInteractionState.swift)
owns:

- The materialized focus context buffer
- The active suggestion session
- Consumed character count
- The sentinel indicating that Cotabby inserted text but AX has not published it yet

[SuggestionSessionReconciler.swift](../../Cotabby/Support/Suggestion/SuggestionSessionReconciler.swift)
contains the pure rules for comparing a session with live editor state. It tolerates narrowly scoped
post-insertion AX lag while rejecting focus changes, altered trailing text, selection, undo, or
divergent typing.

## Acceptance

The word-accept key follows the configured word or phrase granularity. The full-accept key commits
the entire remaining tail. Acceptance validates:

- Cotabby is still enabled.
- Input Monitoring remains granted.
- The focused field remains supported.
- A live session exists.
- The visible overlay matches the remaining session text.
- Current AX text still reconciles with the session anchor.

Successful insertion advances or exhausts the session. Partial acceptance updates the visible tail
synchronously so a rapid second press cannot observe an overlay/session mismatch.

After final acceptance, Cotabby starts speculative generation against the text the host is expected
to publish. A parallel publish check validates that guess. If the host publishes different content,
ordinary newer work supersedes the speculation.

There is also a short gap between exhausting the visible tail and presenting a regenerated
continuation. [PostExhaustionAcceptanceState.swift](../../Cotabby/Support/Suggestion/PostExhaustionAcceptanceState.swift)
keeps Tab owned only during that bounded window, collapses repeated rapid presses into at most one
queued accept, and keys the timeout to the current arm generation. The coordinator owns the event-tap
and timer effects; the value owns only the transition rules. A timeout or teardown returns Tab to the
host, while a fresh continuation atomically consumes the queued accept.

## Invariants

- Only the current work ID may apply asynchronous results.
- Focus and content signatures are revalidated after awaits.
- An overlay is acceptable only when it matches the active session tail.
- Streamed partials are provisional; the final result is authoritative.
- A cancellation is not automatically a runtime failure.
- Stream drain and post-exhaustion acceptance rules live in pure state values; their timers,
  scheduling, input interception, and presentation effects remain coordinator-owned.
- Native correction runs before model generation.
- AX lag tolerance is narrow and tied to a known Cotabby insertion.
- Pure policy stays in Support; mutable orchestration stays in the coordinator and service owners.

## Failure-Oriented Reading

- Suggestion never starts: availability evaluator, focus capability, settings snapshot.
- Suggestion uses text from before the keypress: host-publish polling and focus refresh timing.
- Old text appears after switching fields: work ID and focus/content signature guards.
- Partial appears then vanishes: final normalization, confidence, or seam suppression.
- Tab passes through despite visible text: overlay/session acceptance validation and input tap state.
- A rapid second Tab escapes after the tail is exhausted: post-exhaustion arm, queued accept, and
  generation-keyed backstop.
- Accepted word repeats: post-insertion reconciliation and speculative-generation validation.
- Typo correction behaves like a continuation: session kind and correction acceptance path.
- Ghost tail jitters after partial acceptance: acceptance presentation and overlay advance logic.

## Update This Guide When

Update this document when a new pipeline state is introduced, a stale-result signature changes,
correction ordering moves, request construction gains a context source, streaming semantics change,
or acceptance/session reconciliation acquires a new invariant.
