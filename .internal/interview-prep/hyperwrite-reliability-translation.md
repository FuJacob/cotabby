# Translating Cotabby into a Reliable HyperWrite Mac Alpha

## Purpose

This document prepares you to discuss how Cotabby's lessons apply to the HyperWrite Mac prototype.
It is not a claim about HyperWrite's current implementation; you have not inspected that prototype
yet. It separates:

- Questions that must be answered during the technical session
- Reliability invariants that apply to almost any cross-application Mac writing assistant
- Cotabby patterns worth transferring
- Cotabby-specific decisions that should not be copied blindly
- A practical sequence for turning a prototype into an alpha users can trust

The goal is to show Josh that you can productize an existing prototype without prematurely rewriting
it or treating model integration as the whole problem.

## The Core Interview Thesis

A strong opening position is:

> I would treat HyperWrite Mac as a cross-application interaction state machine, not just an API
> client with an overlay. The user has to trust that we understand the current editor, never show a
> stale suggestion, never steal an unrelated key, and insert exactly what was accepted. I would first
> instrument the prototype and define those invariants, then harden focus, input, session, insertion,
> and failure recovery around a declared compatibility matrix.

That communicates three things:

1. You understand where Mac-wide autocomplete fails in production.
2. You will learn from the prototype before replacing it.
3. You define reliability in observable behavior rather than general confidence.

## Reliability Is a Product Contract

For this product, reliable should mean:

### Input integrity

- HyperWrite never consumes a key it did not successfully handle.
- Synthetic insertion never re-enters the suggestion pipeline as user typing.
- Shortcut changes take effect predictably.
- An active IME does not cause acceptance to disappear into composition.

### Target correctness

- A suggestion belongs to one focused field and one text seam.
- Switching applications, fields, selections, or documents invalidates incompatible work.
- A late network or model response cannot appear in a newer editor state.

### Session correctness

- Visible suggestion text and the active remaining tail agree.
- Type-through advances only on exact matching characters.
- Partial acceptance inserts one deterministic chunk.
- A final stream result cannot silently corrupt an already accepted session.

### Insertion correctness

- Accepted text is committed through a strategy appropriate to the host and input method.
- The original acceptance key is consumed only when the write path succeeds.
- The host's subsequent state is reconciled; posting an event is not considered proof.
- Clipboard fallbacks preserve user data and respect newer clipboard changes.

### Presentation correctness

- HyperWrite UI never steals focus from the assisted editor.
- Approximate caret geometry is not presented as exact.
- The overlay stays within the correct screen/Space and degrades when positioning is uncertain.
- Hiding or advancing presentation cannot leave an accept-ready invisible session.

### Availability and recovery

- Missing permissions, network, authentication, model availability, sleep/wake, or host exit produce
  explicit recoverable states.
- Cancellation is normal lifecycle, not an alarming error.
- Failed prewarm or optional context does not necessarily disable the core loop.
- Shutdown cannot race active native or network work.

### Privacy and security

- Every acquired context source has a permission, lifetime, bound, transport scope, and disclosure.
- Secure fields are rejected at the earliest practical acquisition boundary.
- Credentials use platform secret storage.
- Debug artifacts containing user text require an explicit mode and retention policy.

### Observability

- One suggestion can be traced from focus to request to stream to presentation to acceptance.
- Failures are classified by stage and reason rather than flattened into “did not work.”
- Metrics distinguish unsupported hosts from product regressions.

## What Is Known and What Is Not

Known from Josh's message:

- There is a current HyperWrite Mac prototype.
- The objective is a strong Mac alpha.
- The technical session is intended to examine architecture and approach.
- Reliability and longer-term engineering fit are part of the evaluation.

Unknown until the session:

- Whether the app is Swift/AppKit/SwiftUI, Electron, Catalyst, or mixed
- How it discovers focused editors
- Whether it uses AX polling, notifications, event taps, or application-specific integration
- Which keys it observes or consumes
- Whether generation is local, hosted, hybrid, or streamed
- How request identity and cancellation work
- How it positions and owns its overlay
- How it inserts accepted text
- Which applications and languages are in alpha scope
- What telemetry or diagnostics already exist
- How it is signed, distributed, updated, and granted TCC permissions
- Which prototype failures are already known

Do not fill these gaps with assumptions. Use them to demonstrate disciplined discovery.

## Questions to Ask During the Technical Session

### Product contract

- What is the smallest user journey that must feel excellent in the alpha?
- Is the primary interaction inline autocomplete, rewrite commands, chat, or several modes?
- What applications are explicitly in scope?
- Are browsers, Electron editors, native fields, Office apps, and IDEs equally important?
- Are multiline, mid-line, and selected-text operations required?
- What are the intended acceptance and dismissal gestures?
- What does Josh mean by “strong alpha”: internal dogfood, invited users, or public release?
- Which current prototype behaviors are most embarrassing or unreliable?

### Focus and editor state

- How is the focused editable element discovered today?
- What representation of text, selection, and caret geometry is treated as authoritative?
- How are browser iframes and custom editors handled?
- Are secure/read-only/terminal fields classified?
- Is text bounded before it enters application state?
- What identifies the same field across AX element replacement?
- Is there a known compatibility matrix?

### Input

- Does the prototype use CGEvent taps, NSEvent global monitors, local monitors, or another mechanism?
- Is the tap listen-only or capable of consuming events?
- Under what exact condition is an acceptance key swallowed?
- How are synthetic writes distinguished from physical input?
- How do shortcut changes and modifier state interact with active capture?
- What happens when Input Monitoring permission is revoked?

### Request and generation

- Where is an immutable request assembled?
- Which context sources can be included?
- Is generation streamed, and are partials cumulative or deltas?
- What backend owns authentication, retries, timeout, and cancellation?
- Can responses arrive out of order?
- Is there request or session identity across client and server logs?
- What quality cleanup happens before display?
- What is the desired behavior when the backend is slow or offline?

### Presentation

- Is the overlay an NSPanel, SwiftUI scene, Electron window, or host-integrated view?
- Can it become key or steal focus?
- How is caret geometry obtained and classified?
- What happens when exact geometry is unavailable?
- How are multiple displays, Spaces, full-screen apps, RTL, and multiline text handled?
- Can a visible partial be accepted before the final response?

### Insertion

- Does acceptance use Unicode events, AX value mutation, paste, menu commands, or per-app strategies?
- How is the host result verified?
- How are IMEs handled?
- What happens if the host ignores or transforms the inserted text?
- If the clipboard is used, how are all representations restored?
- Are replacements and forward continuations represented differently?

### Privacy

- Which user text and screen context leaves the machine?
- What is stored by the client and server?
- Are screenshots or OCR involved?
- How are secure fields excluded?
- Where are credentials stored?
- What does debug logging contain and how long is it retained?
- Which privacy claims are already public?

### Distribution and operations

- What macOS versions and hardware are supported?
- Is the app sandboxed? Why or why not?
- How are signing, notarization, entitlements, and updates handled?
- Are development and production TCC identities separate?
- Is there a crash-reporting or support-diagnostics path?
- How are releases rolled back?

### Code and team

- Which parts of the prototype are considered sound and should be preserved?
- Where does Josh expect architectural change?
- What tests exist?
- What build/release automation exists?
- Who decides product tradeoffs during the trial?
- What access, designs, backend contracts, and user feedback will be available?

## How to Inspect the Prototype Live

Ask Josh to demonstrate one successful suggestion and one known failure. Trace both through the same
questions:

~~~text
What editor state did the app observe?
  -> What event triggered work?
  -> What request identity was created?
  -> What context was sent?
  -> What backend operation ran?
  -> What partial/final output returned?
  -> What state became accept-ready?
  -> What window displayed it?
  -> What consumed the acceptance key?
  -> What inserted text?
  -> How was host success verified?
  -> Which logs prove the path?
~~~

Do not start with “I would rewrite this.” Start with:

- Where is the state owned?
- Which invariant is implicit?
- Which boundary lacks identity or observability?
- Is the observed failure deterministic, host-specific, or timing-specific?
- Can the current component be wrapped behind a reliable contract?

## Provisional Risk Register

These risks should be validated, not assumed.

| Risk | User-visible failure | First evidence to seek | Cotabby lesson |
| --- | --- | --- | --- |
| Stale focus | Suggestion appears in the wrong field | Focus/session identifiers in logs | focusChangeSequence plus content signatures |
| AX publish lag | Prompt omits the latest character | Event and AX capture timestamps | bounded host-publication polling |
| Consuming tap ownership | Tab or another key disappears | Tap mode and accept verdict | listen-only observer plus fail-open accept tap |
| Out-of-order network stream | Old partial replaces newer state | Request IDs and stream sequence | work identity and monotonic partial policy |
| Weak caret geometry | Overlay floats or overlaps text | Geometry source/quality | quality-aware inline versus mirror |
| Insertion mismatch | Accepted text is missing or duplicated | Planned write versus fresh host state | insertion strategy plus reconciliation |
| IME composition | Acceptance re-enters composition | Input source and insertion method | IME-aware paste commit |
| Clipboard corruption | User loses clipboard contents | Pasteboard snapshot/restore logs | all-representation, change-aware restore |
| Permission drift | App works after install but not restart | TCC state and code identity | explicit permission model and dev identity |
| Backend outage | UI hangs or stale ghost remains | Timeout/cancel state | recoverable engine state and cancellation |
| Unbounded context | Latency, cost, or privacy leak | Request-size breakdown | acquisition bounds plus section budgets |
| Native/resource leak | Memory grows across sessions | model/window/task lifecycle | selected-runtime lifecycle and bounded shutdown |
| App-specific AX behavior | One host breaks while others pass | compatibility matrix | isolated fallbacks behind focus/geometry services |
| Poor observability | Team cannot reproduce reports | missing correlation/stage metadata | request-correlated structured logs |

## A Provisional Target Architecture

The exact types should follow the prototype language and framework, but the responsibilities should
look like this:

~~~text
ApplicationEnvironment
  owns app-lifetime services and configuration

FocusProvider
  reduces host APIs into bounded FocusSnapshot values

InputMonitor
  observes physical intent and conditionally consumes owned actions

SuggestionCoordinator
  owns state transitions, not low-level OS or model mechanics

WorkController
  owns debounce, cancellation, and current work identity

ContextBuilder
  builds one immutable bounded request

SuggestionEngine
  streams backend results behind one contract

OutputNormalizer
  enforces backend-independent display and insertion policy

InteractionSession
  owns active anchor, remaining text, type-through, and acceptance state

OverlayController
  owns non-activating presentation and geometry degradation

Inserter
  selects a host/IME-safe write strategy and reports the plan/result

Diagnostics
  correlates focus, request, stream, presentation, and acceptance
~~~

This is not a demand for eleven classes. It is a responsibility map. Several can begin as small value
types or protocols around working prototype code.

## Cotabby Patterns Worth Transferring

### One composition root

Transfer the invariant that process-wide focus monitors, event taps, panels, and sessions have one
owner. The HyperWrite implementation may use dependency injection, an application environment, or
another composition mechanism.

Cotabby references:

- [CotabbyAppEnvironment.swift](../../Cotabby/App/Core/CotabbyAppEnvironment.swift)
- [AppDelegate.swift](../../Cotabby/App/Core/AppDelegate.swift)

### Normalized bounded focus state

Do not let every subsystem call AX independently. Reduce host state once into a value carrying
capability, text window, selection, identity, geometry quality, and surface metadata.

Cotabby references:

- [FocusSnapshotResolver.swift](../../Cotabby/Services/Focus/FocusSnapshotResolver.swift)
- [FocusModels.swift](../../Cotabby/Models/Focus/FocusModels.swift)

### Explicit work identity

Cancellation must be paired with a generation/work identifier and environment signatures. Network
responses are especially likely to finish after cancellation.

Cotabby references:

- [SuggestionWorkController.swift](../../Cotabby/Services/Suggestion/SuggestionWorkController.swift)
- [SuggestionCoordinator+Prediction.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator+Prediction.swift)

### A real interaction session

Represent active suggestion state explicitly. Store its anchor, full text, consumed portion,
trailing-text expectation, and kind. Do not infer the session from whatever the overlay currently
shows.

Cotabby references:

- [SuggestionInteractionState.swift](../../Cotabby/Services/Suggestion/SuggestionInteractionState.swift)
- [SuggestionSessionReconciler.swift](../../Cotabby/Support/Suggestion/SuggestionSessionReconciler.swift)

### Small pure state machines for timing-sensitive mechanisms

When several booleans and counters protect one timing invariant, move their transitions into a
small value while leaving scheduling and side effects with the coordinator. This makes race rules
executable without pretending the value owns event taps, timers, or windows.

Cotabby references:

- [SuggestionStreamingState.swift](../../Cotabby/Support/Suggestion/SuggestionStreamingState.swift)
- [PostExhaustionAcceptanceState.swift](../../Cotabby/Support/Suggestion/PostExhaustionAcceptanceState.swift)
- [SuggestionStreamingStateTests.swift](../../CotabbyTests/Support/Suggestion/SuggestionStreamingStateTests.swift)
- [PostExhaustionAcceptanceStateTests.swift](../../CotabbyTests/Support/Suggestion/PostExhaustionAcceptanceStateTests.swift)

### Fail-open input

Keep ordinary observation non-consuming. Enable interception only while a feature owns a key, and
swallow the key only after the action succeeds.

Cotabby reference:

- [InputMonitor.swift](../../Cotabby/Services/Input/InputMonitor.swift)

### Strategy-based insertion

Treat Unicode events, menu paste, Command-V, AX mutation, and replacements as strategies with
explicit preconditions and failure behavior. Detect composing IMEs. Reconcile afterward.

Cotabby references:

- [SuggestionInserter.swift](../../Cotabby/Services/Suggestion/SuggestionInserter.swift)
- [InsertionStrategySelector.swift](../../Cotabby/Support/Suggestion/InsertionStrategySelector.swift)

### Uncertainty-aware presentation

Carry geometry quality into presentation. If HyperWrite cannot know an exact caret, use a UI that
looks intentionally approximate instead of misaligned inline text.

Cotabby references:

- [CompletionRenderModePolicy.swift](../../Cotabby/Support/Presentation/CompletionRenderModePolicy.swift)
- [OverlayController.swift](../../Cotabby/Services/Presentation/OverlayController.swift)

### Bounded context at acquisition and rendering

Bound user text before it circulates through state, then budget it again when creating a request.
Treat each optional context source as a separate privacy boundary.

Cotabby references:

- [FocusSnapshotResolver.swift](../../Cotabby/Services/Focus/FocusSnapshotResolver.swift)
- [SuggestionRequestFactory.swift](../../Cotabby/Support/Suggestion/SuggestionRequestFactory.swift)
- [PromptContextSanitizer.swift](../../Cotabby/Support/Context/PromptContextSanitizer.swift)

### Correlated observability

Create request/session/focus identifiers early and carry them across client/server if possible.
Record state transitions and suppression reasons, not only errors.

Cotabby references:

- [RequestID.swift](../../Cotabby/Support/Logging/RequestID.swift)
- [SuggestionDebugLogger.swift](../../Cotabby/Services/Suggestion/SuggestionDebugLogger.swift)

## Cotabby Decisions Not to Copy Blindly

### Polling

Polling is Cotabby's authoritative choice because of observed AX notification inconsistency. If
HyperWrite already has a reliable notification-plus-reconciliation design or a narrower host set,
measure it before replacing it. The transferable idea is one authoritative freshness model.

### App-specific fallbacks

Cotabby has Chromium, Calendar, static-run, and geometry workarounds accumulated from real hosts.
HyperWrite should add compatibility branches only for supported-product evidence, behind a narrow
boundary and regression case.

### Llama runtime structure

If HyperWrite is hosted-only, LlamaRuntimeManager/Core and KV-cache lifecycle are irrelevant. The
transferable ideas are serialized mutable backend state, cancellation, prewarm, and cleanup.

### Coordinator shape

Do not copy a large coordinator file layout. Copy the distinction between orchestration, mutable
session state, work identity, pure policy, and small mechanism-specific state machines.

### Every Cotabby feature

Emoji, macros, visual OCR, power profiles, multiple backends, and extensive settings are not
prerequisites for a reliable HyperWrite alpha. Additional surface area multiplies the compatibility
matrix.

### Current secure-field acquisition

Cotabby's secure-field generation block occurs later than the ideal acquisition boundary. HyperWrite
should make the desired privacy invariant explicit before copying focus or visual-context behavior.

## Work Sequence for an Alpha

This is sequencing, not a calendar.

### Phase A: Establish the baseline

Outputs:

- Build and run instructions that work from a clean checkout
- A written current architecture and data-flow trace
- A list of known failures with reproduction steps
- Structured stage logging with correlation IDs
- Initial latency, crash, input, and insertion measurements
- A provisional supported-application matrix

Why first:

Without a baseline, architectural changes cannot be distinguished from regressions and the team will
optimize the most memorable anecdote.

### Phase B: Define the interaction contract

Outputs:

- FocusSnapshot or equivalent bounded value
- Explicit capability and block reasons
- Request/work identity
- Active interaction session
- Rules for invalidation, type-through, dismissal, and acceptance
- One definition of visible-versus-accept-ready state

Why:

This turns implicit timing into testable state transitions.

### Phase C: Harden focus and input

Outputs:

- One authoritative focus freshness mechanism
- Supported-host capability resolution
- Secure/read-only exclusion
- Fail-open input observation/interception
- Synthetic-event suppression
- Permission recovery
- Stress tests for rapid typing, field switching, and modifier changes

Why:

No generation improvement matters if the wrong editor is targeted or a physical key disappears.

### Phase D: Harden request and generation

Outputs:

- Immutable bounded request builder
- Backend timeout, cancellation, and retry policy
- Streaming sequence/monotonicity contract
- Backend-independent output normalization
- Explicit unavailable/degraded states
- Client/server request correlation where available

Why:

Network/model uncertainty becomes an ordinary state instead of corrupting UI state.

### Phase E: Harden presentation and insertion

Outputs:

- Non-activating overlay ownership
- Geometry quality and fallback presentation
- Session/overlay equality checks
- Host and IME-aware insertion strategy
- Post-insertion verification
- Clipboard protection if paste is used
- Multiple display, Space, full-screen, RTL, and multiline checks appropriate to scope

Why:

This is the point where users either trust the product or feel that it interferes with their work.

### Phase F: Productize distribution and recovery

Outputs:

- Clear permission onboarding and recovery
- Stable development and production identities
- Signing/notarization/update path
- Privacy disclosure matching actual context transport
- Debug artifact policy
- Crash/hang and support-diagnostics workflow
- Release rollback plan

Why:

A reliable debug build is not yet a reliable product.

### Phase G: Alpha hardening

Outputs:

- Executed compatibility matrix
- Adversarial and soak results
- Measured alpha gates
- Known limitations and non-goals
- Triage playbook
- Prioritized post-alpha roadmap

Why:

Alpha quality should be a deliberate support boundary, not “it worked in the demo.”

## Observability Contract

Every suggestion should carry identifiers such as:

- focus_session_id
- request_id
- interaction_session_id
- stream_sequence
- insertion_attempt_id

Useful stages:

~~~text
focus_captured
focus_blocked
input_observed
host_publish_wait_started
request_built
request_dispatched
first_partial
partial_presented
final_received
result_suppressed
session_started
accept_requested
insert_attempted
insert_verified
insert_mismatch
session_invalidated
request_cancelled
~~~

Each stage should carry only safe metadata by default:

- Host application and surface classification
- Focus/content signature, not raw text
- Backend and model
- Latency
- Geometry source/quality
- Context character counts by source
- Suppression or failure reason
- Insertion strategy and outcome

Full text or screenshots should require an explicit diagnostic mode with local retention and clear
consent. If the HyperWrite server already has request IDs, the client request ID should cross the
transport boundary.

## Failure and Recovery Matrix

| Failure | Safe behavior | Diagnostic evidence |
| --- | --- | --- |
| No focused supported field | Hide/disable suggestion; consume nothing | capability reason |
| AX state older than input | bounded refresh/poll, then ordinary guards | event and capture ages |
| Field switch during request | cancel and reject late response | request/focus identity mismatch |
| Stream sends non-monotonic partial | hold last valid partial or reset safely | stream sequence and texts in explicit debug |
| Backend timeout | clear provisional state and show recoverable status if appropriate | backend latency and timeout classification |
| Authentication failure | stop retries, prompt settings repair | endpoint identity and HTTP classification |
| Overlay geometry invalid | suppress or use deliberate fallback UI | geometry source/quality |
| Acceptance session stale | pass the original key through | accept preflight reason |
| IME active | use verified commit strategy | input source and insertion strategy |
| Paste menu unavailable | safe fallback or fail open | menu lookup/press result |
| Host write not published | bounded refresh, invalidate speculation/session | insertion attempt and content mismatch |
| Permission revoked | tear down consuming taps and surface guidance | permission transition |
| App sleeps/wakes | refresh permissions/focus/backend and discard old sessions | lifecycle generation |
| Process termination | stop new work, cancel/flush, release resources | shutdown stage durations |

## Test Strategy

### Pure unit tests

Test value-based rules without a desktop:

- Capability/availability decisions
- Request bounds and context budgets
- Work identity
- Session transitions
- Type-through
- Word/phrase segmentation
- Stream monotonicity
- Output normalization
- Geometry-mode policy
- Insertion planning
- Clipboard restore decisions
- Retry/timeout classification

### Coordinator tests with fakes

Inject fake focus, engine, overlay, and inserter boundaries. Test:

- Late result rejection
- Field switch during generation
- Partial then final suppression
- Accept preflight failure passing through
- Host publication lag
- Permission and settings changes
- Backend switching

### Controlled host fixtures

Build small test hosts that expose known behavior:

- Native NSTextField and NSTextView
- Secure and read-only fields
- Multiline and mid-line content
- WebKit contenteditable
- A deliberately delayed AX publisher if feasible
- An IME/manual composition procedure

These fixtures make regressions reproducible before testing third-party applications.

### Supported-application matrix

For each declared host, test:

- Empty, beginning, middle, and end-of-line caret
- Selection and replacement
- Rapid typing and deletion
- Partial and full acceptance
- Focus switch while streaming
- Undo/redo
- Multiple windows
- Multiple displays/Spaces/full screen
- Light/dark and accessibility display settings
- Relevant IMEs and RTL if in scope
- Permission revoke/regrant
- Network loss/recovery if hosted

### Adversarial tests

- Responses intentionally complete out of order
- Cancellation arrives during every async stage
- User changes clipboard during paste restore
- Acceptance is pressed twice rapidly
- Host exits during capture or insertion
- Selected engine/account changes during stream
- Machine sleeps during request
- AX returns malformed or non-finite geometry
- Backend sends control tokens, prompt echoes, or an empty final

### Soak and resource tests

- Continuous typing and focus switching
- Repeated overlay show/hide
- Repeated backend reconnect/prewarm
- Memory stability
- Event-tap recovery
- Idle CPU/wake behavior
- Clean termination under in-flight work

## Candidate Alpha Gates

These are starting proposals to calibrate with Josh, not promises before a baseline.

### Non-negotiable correctness

- Zero swallowed non-owned keys in automated classification/replay tests
- Zero stale results applied in the adversarial focus/request suite
- Zero focus-stealing overlay events
- Zero secure-field generation requests
- Zero clipboard loss in restore and overlapping-paste tests

### Supported-host reliability

- A measured insertion success target, such as at least 99 percent, in the declared application
  matrix
- Every failure is either a known explicit degradation or produces a correlated diagnostic trail
- No silent accept where UI claims success but the host did not mutate

### Performance

- Define p50 and p95 time-to-first-useful-partial after measuring the current prototype
- Define p95 input-to-overlay update separately from backend latency
- No unbounded memory growth during repeated sessions
- Idle focus monitoring remains within an agreed CPU/wake budget

### Stability and recovery

- No crashes or hangs in the agreed soak scenario
- Permission revoke/regrant produces a recoverable state
- Network loss, authentication failure, and timeout do not leave a stale accept-ready session
- Sleep/wake and app relaunch clear incompatible state

### Privacy

- Context inventory matches product disclosure
- Secure-field behavior is covered by acquisition and request tests
- Credentials use Keychain or an equivalent platform secret boundary
- Full-content diagnostics are explicit, local/authorized, and retained according to policy

## Scope Control

A credible alpha scope is stronger than a universal claim.

Define:

- Supported macOS versions
- Supported processor requirements
- Named first-class applications
- Best-effort applications
- Unsupported sensitive or unusual fields
- Supported languages and IMEs
- Supported editing shapes
- One primary generation path
- One acceptance interaction
- Explicit offline/network behavior

Potential early non-goals:

- Every custom editor on macOS
- Perfect inline placement when caret geometry is unavailable
- Multiple generation backends
- Screenshot context
- Complex partial-word/phrase customization
- Broad application-specific settings
- Deterministic correction, emoji, or macros

Non-goals are not admissions of failure. They protect the reliability promise.

## Trial Deliverables to Discuss

A strong working trial can produce:

- A verified architecture map of the existing HyperWrite prototype
- Correlated diagnostics for the core suggestion loop
- An agreed alpha compatibility matrix
- A written reliability contract and measurable gates
- Hardened focus/input/session/insertion boundaries
- A tested primary generation path
- Permission, signing, and distribution readiness
- Known limitations and a post-alpha roadmap

The exact selection depends on prototype maturity. Do not commit to all deliverables before seeing
the code and current build/release state.

## How to Answer “What Would You Do First?”

### Short answer

> I would get the prototype running, reproduce one successful flow and the highest-impact failures,
> and add correlated stage logging if it is missing. Then I would write down the focus, work,
> session, input-consumption, and insertion invariants. That tells us whether we need targeted
> hardening or a deeper boundary change. I would prioritize wrong-target, swallowed-key, and
> insertion failures before model quality or feature breadth.

### Deeper answer

> My first deliverable would be a measurable baseline and risk map, not a rewrite. I would trace one
> suggestion from the focused editor through input, request, stream, overlay, acceptance, and host
> verification. I would make each stage share a request identity and classify current failures. Then
> I would harden the smallest trusted loop for an agreed app matrix: authoritative focus snapshot,
> fail-open input, cancellation plus work identity, one active interaction session, one generation
> contract, non-activating presentation, and verified insertion. Once that loop is reliable, we can
> broaden compatibility and context without multiplying unknowns.

## How to Answer “Why Are You a Fit?”

> Cotabby forced me to solve the same class of problems that turn a Mac autocomplete demo into a
> product: Accessibility inconsistency, browser and Electron behavior, global input without stealing
> focus, stale async generation, streaming session state, caret geometry, IMEs, safe insertion,
> permissions, native runtime lifecycle, and correlated debugging. I would not assume HyperWrite
> needs Cotabby's exact implementation, but I know which invariants to look for, how to isolate the
> risky boundaries, and how to scope reliability around evidence from real host applications.

## Warning Signs During Scoping

Ask for clarification if:

- “Works everywhere” has no application matrix
- The acceptance key is consumed before insertion success is known
- Responses have no request/focus identity
- Raw editor or screenshot context is unbounded
- The prototype has no way to correlate a user report to one suggestion
- A network retry can outlive the editor session
- Overlay visibility is treated as the source of session truth
- Synthetic input is not distinguishable from physical input
- Hosted context transport is described as fully local
- Signing/TCC/update work is deferred until after the alpha

Do not use warning signs to criticize the prototype. Use them to ask precise questions and propose a
reliability boundary.

## Cotabby Study References for the Session

Review these immediately before the discussion:

1. [Root architecture map](../../ARCHITECTURE.md)
2. [Suggestion Pipeline](../architecture/suggestion-pipeline.md)
3. [Focus and Accessibility](../architecture/focus-and-accessibility.md)
4. [Input and Insertion](../architecture/input-and-insertion.md)
5. [Inference and Prompting](../architecture/inference-and-prompting.md)
6. [Context, Privacy, and Permissions](../architecture/context-privacy-and-permissions.md)
7. [Technical Decision Question Bank](technical-question-bank.md)

The most relevant concrete source files are:

- [CotabbyAppEnvironment.swift](../../Cotabby/App/Core/CotabbyAppEnvironment.swift)
- [FocusTracker.swift](../../Cotabby/Services/Focus/FocusTracker.swift)
- [FocusSnapshotResolver.swift](../../Cotabby/Services/Focus/FocusSnapshotResolver.swift)
- [InputMonitor.swift](../../Cotabby/Services/Input/InputMonitor.swift)
- [SuggestionWorkController.swift](../../Cotabby/Services/Suggestion/SuggestionWorkController.swift)
- [SuggestionInteractionState.swift](../../Cotabby/Services/Suggestion/SuggestionInteractionState.swift)
- [SuggestionCoordinator+Prediction.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator+Prediction.swift)
- [SuggestionCoordinator+Acceptance.swift](../../Cotabby/App/Coordinators/SuggestionCoordinator+Acceptance.swift)
- [SuggestionInserter.swift](../../Cotabby/Services/Suggestion/SuggestionInserter.swift)
- [OverlayController.swift](../../Cotabby/Services/Presentation/OverlayController.swift)
- [SuggestionEngineRouter.swift](../../Cotabby/Services/Runtime/SuggestionEngineRouter.swift)
- [SuggestionRequestFactory.swift](../../Cotabby/Support/Suggestion/SuggestionRequestFactory.swift)
- [SuggestionSessionReconciler.swift](../../Cotabby/Support/Suggestion/SuggestionSessionReconciler.swift)

## Final Position

The interview is not about proving that Cotabby is perfect. It is about proving that you can:

- Explain a complex existing system accurately
- Identify reliability invariants from first principles
- Name tradeoffs and current debt honestly
- Investigate a prototype before prescribing a rewrite
- Convert failure modes into boundaries, tests, and measurable alpha gates
- Scope product breadth around what users can trust

That is the bridge from Cotabby architecture to HyperWrite product engineering.
