# Ghostype Codex Instructions

## Project Identity

Ghostype is a macOS menu bar app for local-first inline autocomplete. The core loop is:

1. Track the currently focused editable field through Accessibility.
2. Monitor global keyboard input without stealing focus.
3. Decide whether the field, permissions, settings, and runtime are eligible.
4. Build an autocomplete request from the focused text context and optional visual context.
5. Generate through Apple Intelligence, in-process llama.cpp, or a configured OpenAI-compatible
   endpoint.
6. Normalize the model output into a short continuation.
7. Render ghost text near the caret.
8. Insert accepted chunks when the user presses `Tab` while keeping the remaining tail alive.

Apple Intelligence and llama.cpp run on the Mac. The endpoint backend may send the same bounded
request to loopback, LAN, or public HTTPS when the user explicitly selects it. Do not add or broaden
hosted transmission without explicit user scope and clear disclosure.

## Learning-First Collaboration

- Explain both the "what" and the "why" for architecture and code changes.
- Assume the user is actively learning Swift, AppKit, Accessibility APIs, llama.cpp integration,
  async/await, actor isolation, and macOS app architecture.
- Teach at the file, type, and subsystem level, not just the line level.
- Call out tradeoffs when there are multiple valid approaches.
- Prefer clean boundaries over quick coupling, especially across `App`, `UI`, `Services`, `Models`,
  and `Support`.

When creating or editing a file, explain:

- what the file is responsible for
- why the file exists as its own boundary
- which objects own it or collaborate with it
- how data flows into and out of it

When adding a `struct`, `class`, `enum`, actor, or protocol, explain:

- what responsibility it owns
- what other objects it collaborates with
- why it should exist as its own type instead of being folded into another file
- how long it lives and who owns it

## Repository Map

- `Ghostype/App/`: app entrypoint, composition root, lifecycle wiring, and coordinators.
- `Ghostype/UI/`: SwiftUI presentation grouped into menus, settings, onboarding, overlays, inline
  features, and reusable components.
- `Ghostype/Services/`: side effects and OS/runtime boundaries. AppKit panel controllers live under
  `Presentation`; other folders own focus, input, context, insertion, visual capture, inference,
  model management, permissions, power, spelling, and updates.
- `Ghostype/Models/`: shared values, settings snapshots, states, domain models, and contracts grouped
  by subsystem.
- `Ghostype/Support/`: deterministic policy, prompting, normalization, reconciliation, geometry,
  sanitization, logging, and low-level bridging helpers grouped by subsystem.
- `GhostypeTests/`: unit and microbench tests that mirror the production subsystem map. Prefer
  testing pure `Support/` and `Models/` logic when possible.
- `CotabbyInference`: the llama.cpp wrapper, consumed as a SwiftPM package
  (`github.com/FuJacob/cotabbyinference`). The build workspace pins a revision and applies
  `patches/cotabbyinference-upstream-pending.patch` until those APIs are accepted upstream.

Within a subsystem, child folders describe stable responsibilities rather than Swift namespaces.
Examples include `Services/Runtime/{AppleIntelligence,Llama,OpenAICompatible}` and
`Support/Suggestion/{Request,Output,Acceptance,Session,Streaming}`. Keep a cohesive small subsystem
flat; add a child folder only when at least two files share a responsibility that a maintainer can
predict from its name. `SOURCE_LAYOUT.md` is the canonical placement map, and tests should mirror
the production responsibility wherever a direct correspondence exists.

## App Ownership

Start here when you need to understand lifecycle:

1. `Ghostype/App/Core/CotabbyApp.swift`
2. `Ghostype/App/Core/AppDelegate.swift`
3. `Ghostype/App/Core/CotabbyAppEnvironment.swift`

`CotabbyAppEnvironment` builds the long-lived dependency graph once. `AppDelegate` starts, stops,
and wires cross-subsystem subscriptions. SwiftUI views should observe objects from that graph
rather than creating services directly.

`SuggestionSettingsModel` remains the individually `@Published` UI-facing compatibility surface.
Its `domainSettings` projection groups the same durable values into general, engine, completion,
context, correction, presentation, inline-feature, and shortcut domains. `SuggestionSettingsStore`
keeps the existing flat UserDefaults keys stable, and `SuggestionSettingsSnapshot` is the immutable
behavior boundary consumed by the suggestion pipeline.

This ownership rule prevents duplicate Accessibility observers, duplicate input monitors, runtime
reload races, and mismatched settings state.

## Suggestion Pipeline

Read the coordinator in this order:

1. `Ghostype/App/Coordinators/Suggestion/SuggestionCoordinator.swift`
2. `Ghostype/App/Coordinators/Suggestion/SuggestionCoordinator+Lifecycle.swift`
3. `Ghostype/App/Coordinators/Suggestion/SuggestionCoordinator+Input.swift`
4. `Ghostype/App/Coordinators/Suggestion/SuggestionCoordinator+Prediction.swift`
5. `Ghostype/App/Coordinators/Suggestion/SuggestionCoordinator+Acceptance.swift`

The coordinator owns orchestration plus active suggestion and presentation state. It should not
absorb every rule or state transition. Prefer:

- `SuggestionRequestFactory` for pure request construction
- `SuggestionAvailabilityEvaluator` for pure gating decisions
- `SuggestionSessionReconciler` for acceptance and active-tail reconciliation
- `SuggestionTextNormalizer` for backend-independent output cleanup
- `SuggestionWorkController` for generation task identity/cancellation
- `SuggestionInteractionState` for active suggestion session storage
- `SuggestionStreamingState` for latest-wins partial coalescing and monotonic rendering state
- `PostExhaustionAcceptanceState` for the bounded rapid-accept window after a tail is exhausted

This split matters because autocomplete is a state machine. Pure rules are easier to test and reason
about than coordinator mutations.

## Focus And Accessibility

Focus and geometry live in:

- `FocusTracker`: observes focus/value/selection changes and publishes snapshots.
- `FocusSnapshotResolver`: reduces raw AX elements into Ghostype-supported focus snapshots.
- `AXTextGeometryResolver`: resolves caret and input geometry.
- `AXHelper`: low-level Accessibility/Core Foundation helper calls.
- `FocusModels`: pure focus values, identities, capabilities, stale-result signatures, and the
  lightweight `FocusPollingEvent` used by the developer overlay.

Accessibility data is eventually consistent and app-specific. Browser editors, Electron apps,
native AppKit fields, and secure fields expose different AX shapes. Preserve stale-result guards,
`focusChangeSequence`, and capability checks unless the change explicitly replaces them. Known
shapes worth keeping in mind: CodeMirror (Obsidian) exposes a wrapped paragraph as one static-text
run plus a single-space spacer run per line, and its value runs paragraphs together with no
separator, so a paragraph is found from where its run was anchored in the value, never from the
last line break (`WrappedRunAnchor` hands both that run and a single-line paragraph run to
`PixelCaretLocator`, which reads the caret from the run's pixels, a one-line run in its own line
box, and carries it forward by the typed advance while the ghost covers the run);
Chromium's address bar keeps its inline completion selected after the caret (stripped by the
resolver and held as the host's marked text, never treated as a user selection) and answers every
bounds query with a zero rect (the caret comes from its pixels, `PixelCaretLocator`); Mail's compose
header rows are `AXTextField`s with identifiers `Mail.toField`, `Mail.ccField`, `Mail.subjectField`
where Tab moves to the next field, so they are blocked (`MailHeaderFieldDetector`), and the body is
an `AXWebArea` described "message body". Chromium composers report `AXPlaceholderValue` only while
empty (the Claude desktop composer's "Type / for commands." disappears a poll or two after the first
character and comes back when the field is cleared), so `FocusedInputPollingSignature` treats a
disappearing placeholder as no evidence and only a different shown placeholder as navigation. A Chromium or Electron host reports its font size in CSS
pixels and nothing of its zoom (the Claude desktop composer reports 14 and paints 15.4 at 110%),
and a contenteditable answers no width query: the ghost's size there follows the advance measured
from the caret's own movement (`CaretAdvanceSampler`), and the faces such a host bundles in its
own `Contents/Resources` are registered for the pixel match (`HostBundledFontRegistry`).

## Visual Context And OCR

Visual context currently flows through:

- `VisualContextCoordinator`: field-scoped visual-context session lifecycle.
- `ScreenshotContextGenerator`: screenshot -> OCR -> `OCRTextHygiene` cleanup -> bounded excerpt.
- `WindowScreenshotService`: captures the relevant window or region.
- `ScreenTextExtractor`: Vision OCR extraction, carrying per-line recognition confidence.
- `OCRTextHygiene`: pure cleanup of raw OCR (drops low-confidence lines and chrome noise). There is
  no model summarization step; a base model conditions fine on cleaned raw context.
- `FocusedFieldScreenRegion`: the focused field's own frame inside the capture. OCR lines inside it
  are dropped (the field's text is already the caret prefix) and its pixels are left out of the OCR
  cache's pixel hash, so a refresh whose only change is the user's typing reuses the previous OCR
  and yields an identical excerpt instead of a "screen context changed" reset. When Accessibility
  may have cut the field's text to its window around the caret (a long document), or could not read
  the text after the caret, only the caret's line band is excluded.
- `VisualContextExcerptStability`: OCR reads an unchanged screen differently on every refresh
  (truncation flicker, spinner digits, split lines, timers). A refresh that differs only that much
  keeps the excerpt in use byte-identical; a new message or another conversation still replaces it.
- `VisualContextModels`: configuration, status, and excerpt values.

Do not put raw screenshots, unbounded OCR dumps, or noisy AX tree text directly into prompts.
Normalize, bound, and mark unavailable states explicitly. Screen Recording permission is separate
from Accessibility and Input Monitoring.

## Runtime And Prompting

Runtime generation is split by responsibility:

- `SuggestionEngineRouter`: selects Apple Intelligence, Open Source, or the configured
  OpenAI-compatible endpoint and owns the narrow Apple-to-llama language fallback.
- `FoundationModelSuggestionEngine`: Apple on-device generation path.
- `LlamaSuggestionEngine`: request-to-prompt, llama result handling, and cache reset handoff.
- `OpenAICompatibleSuggestionEngine`: completion/chat transport, SSE streaming, and Ollama preload
  behavior for the configured endpoint.
- `LlamaRuntimeManager`: UI-facing runtime state, model selection, warmup, and lifecycle control.
- `LlamaRuntimeCore`: explicitly serialized native boundary around mutable llama.cpp pointers,
  prompt tokenization, KV-cache reuse, built-in sampler delegation, cancellation, and shutdown.
- `BaseCompletionPromptRenderer`: prompt construction for the Open Source path. The llama models are
  now *base* (non-instruct) GGUFs, so this renders a pure text continuation: no instruction preamble,
  custom rules and context fold into a short conditioning preface (a base model conditions on
  description, it does not obey commands), sections are character-budgeted via `PromptSectionBudget`,
  and the caret prefix comes last. `FoundationModelPromptRenderer` stays instruct-shaped because
  Apple's Foundation Models path gives us a first-class instructions channel.

`LlamaRuntimeCore` is not a Swift actor. Its locks and lifecycle condition keep native pointer,
cache/decode, and shutdown work serialized while heavy generation runs away from MainActor. The
manager should publish state; the core should own native correctness.

Ghostype owns one autocomplete sequence. CotabbyInference therefore exposes one live native sequence
backed by llama.cpp slot zero; a changing external sequence ID rejects stale handles after reset.
The Swift generation loop owns the maximum output-token budget.

## UI And Overlays

- Caret refinement is limited to rounding-sized changes; unnamed-font single-line fields require a fresh caret after typing or accepting, because guessed advances and stale session anchors can overlap committed text.
- `OverlayController` owns the ghost-text panel lifecycle and positioning. Ghost glyphs are laid
  out by `GhostTextLayout` in the font `GhostFontResolver` resolves, on the baseline
  `GhostBaselinePolicy` (or a `HostBaselineCalibrator` measurement) gives, wrapping onto the host's
  next lines at the measured pitch. Automatic geometry or fitting failures suppress the ghost;
  only an explicit Popup preference permits a card. GhostTextLayout truncates at verified field
  bounds and GhostTextPanelView clips ink and hints there, because typographic widths do not bound
  italic overhang. Change pure helpers and their tests rather than nudging controller offsets.
- Presentation typography and resolver caches are scoped to the writing session, not recycled AX
  nodes; real field switches discard measurements while composer growth preserves them.
- Stable publication runs lint and the native regression suite before packaging, so failed checks
  cannot put an untested correction into the existing updater.
- `SuggestionOverlayPresenter` decides whether a suggestion should be shown or hidden.
- `ActivationIndicatorController` owns the optional caret/field-edge indicator.
- `FocusDebugOverlayController` is for developer visibility and should stay gated behind debug
  options, not normal user settings.
- Settings panes (under `Ghostype/UI/Settings/Panes/`) and onboarding views should remain
  presentation-focused. Push behavior into services, models, or support helpers.

## Swift And Concurrency Rules

- Use `@MainActor` for UI, AppKit, SwiftUI state, most Accessibility access, and published models.
- Use actors or explicit serialization for mutable native/runtime state.
- Do not block the main actor with OCR, screenshots, model loading, or generation.
- Make cancellation and stale-result checks explicit around async work. The user can keep typing,
  switch apps, focus another field, or accept a partial suggestion while work is still running.
- Prefer narrow protocols from `SuggestionSubsystemContracts.swift` when the coordinator only needs
  behavior, not a concrete service.
- Treat Core Foundation and AX bridging as unsafe boundaries. Add comments that explain ownership,
  casting, and failure handling.

## Teaching Comment Standard

- Add real teaching comments, not labels.
- Prefer file-level and type-level `///` comments that explain purpose, ownership, and design.
- Add targeted inline comments for tricky lifecycle behavior, concurrency, cancellation, AX timing,
  Core Foundation bridging, native pointer state, and macOS quirks.
- Comments should explain why the code is written this way, which invariant it protects, or which
  pitfall it avoids.
- Avoid useless comments that merely restate the code.
- If Swift syntax is likely to be unfamiliar, annotate it briefly the first time it appears in a new
  concept-heavy area. Examples: `@Published`, `@ObservedObject`, `@StateObject`, `@MainActor`,
  `Task`, async/await, actor isolation, closures, convenience initializers, `AXUIElement`,
  `CFTypeRef`, and `unsafeBitCast`.

## Change Strategy

Prefer this order when changing behavior:

1. Pure rules in `Support/`
2. Domain models and contracts in `Models/`
3. Service boundary behavior in `Services/`
4. Coordinator orchestration in `App/`
5. SwiftUI/AppKit presentation in `UI/`

This order reduces regression risk because deterministic code changes before stateful orchestration.
It also creates better tests.

## Debugging & Logs

Ghostype has a structured logging system built for AI-assisted debugging. During development the app
is launched with `-ghostype-debug`, which enables on-disk JSONL sinks in addition to the always-on
Console.app stream.

**Log file locations** (only populated when `-ghostype-debug` is set):

- `~/Library/Logs/Ghostype/ghostype.jsonl` — main event stream. One JSON object per line, with all
  metadata flattened as top-level fields so it can be filtered with `jq`.
- `~/Library/Logs/Ghostype/llm-io.jsonl` — full LLM prompts and completions, one record per
  generation. Shares `request_id` with the main log so a single suggestion can be joined across
  files.
- `~/Desktop/ghostype-ax-dump.txt` — most recent Chrome AX tree snapshot. Overwritten on each
  Chrome focus change (debounced by focused-element identity).
- Rotated previous logs: `*.jsonl.1` (one-step rotation when a file exceeds 10 MB).
- `~/Library/Logs/<app>/strips/` — every calibration strip the overlay captured, as PNG plus a JSON
  sidecar (caret column, size, line text), written only while
  `defaults write <bundle> ghostypeDumpCalibrationStrips -bool YES` is set at launch. Replay one
  through `TypefaceMatcher` offline to see why a face was or was not matched.

**Correlation IDs.** Every prediction gets a `request_id` like `req_a3f9k2lq`, stamped on every log
line touching that request (coordinator state transitions, router selection, engine generation, LLM
I/O capture). Pull a complete history of one suggestion:

```bash
jq 'select(.request_id == "req_a3f9k2lq")' ~/Library/Logs/Ghostype/ghostype.jsonl
jq 'select(.request_id == "req_a3f9k2lq")' ~/Library/Logs/Ghostype/llm-io.jsonl
```

**Useful `jq` recipes:**

```bash
# Recent errors across the app
jq 'select(.level == "error")' ~/Library/Logs/Ghostype/ghostype.jsonl

# Llama generations slower than 500 ms
jq 'select(.engine == "llama" and .latency_ms > 500)' ~/Library/Logs/Ghostype/llm-io.jsonl

# Coordinator state transitions
jq 'select(.category == "suggestion" and .stage != null)' ~/Library/Logs/Ghostype/ghostype.jsonl

# Runtime model load/decode events
jq 'select(.category == "runtime")' ~/Library/Logs/Ghostype/ghostype.jsonl
```

**Symptom → category map:**

- Ghost text didn't appear → `suggestion` + `focus`
- Wrong text inserted → look up the request in `llm-io.jsonl`, then walk `suggestion` for
  acceptance
- Model won't load / decode fails → `runtime` + `models`
- Permission dialog loop → `app` (permission state transitions)
- Chrome-specific weirdness → start with `~/Desktop/ghostype-ax-dump.txt`, then `focus`
- Wrong backend chosen → `suggestion` router selection log (`engine`, `fallback_engine`)

**Console.app fallback** (when `-ghostype-debug` wasn't set):

```bash
log show --predicate 'subsystem == "com.jasshans.ghostype"' --last 10m
log stream --predicate 'subsystem == "com.jasshans.ghostype"' --level debug
```

**Rule of thumb.** When a user reports a bug, first `tail` / `jq` the relevant file with the
symptom → category map. Do not ask the user to re-explain symptoms before checking the logs.

## Builds And Validation

- GitHub macOS workflows use explicit Intel runners to avoid ARM runner capacity stalls; production releases must build and verify both Mac architectures before signing and publication.

Build, run, and test with Xcode as documented in
[`CONTRIBUTING.md`](CONTRIBUTING.md). Prepare the pinned inference workspace with
`scripts/prepare_cotabby_workspace.sh` first. Local launches use the developer's own signing
team configured through `scripts/dev-setup.sh` and the isolated `Ghostype Dev` scheme; production
uses `Ghostype`, its own bundle identity (`com.jasshans.ghostype`), and Sparkle updates. Shared CI uses unsigned compile checks and
app-hosted tests.

Use the narrowest meaningful validation first, then broaden if the change touches shared behavior.
Keep DerivedData in `build/DerivedData`, avoid concurrent builds in the same checkout, and clean
it after validation. Verify cleanup before reporting completion.
Never move DerivedData to `~/Library/Developer/Xcode/DerivedData/Ghostype-*`.

```bash
xcodebuild -project Ghostype.xcodeproj -scheme Ghostype -destination 'platform=macOS' build \
  -derivedDataPath build/DerivedData
xcodebuild -project Ghostype.xcodeproj -scheme Ghostype -destination 'platform=macOS' build-for-testing \
  -derivedDataPath build/DerivedData
```

Always pass `-derivedDataPath build/DerivedData` so the output lands in the repo-scoped `build/`
directory (already gitignored) instead of accumulating under
`~/Library/Developer/Xcode/DerivedData/Ghostype-*`, where every build leaves a fresh multi-GB module
cache and SwiftPM checkout that nothing trims. When a task is done and the artifacts are no longer
needed, `rm -rf build/DerivedData` before reporting completion.

Two model-backed eval suites measure suggestion quality and are local-only (they need a downloaded
GGUF and are gated behind the `RUN_LLAMA_EVAL` compile flag). `test_reportEvalSuite` scores ordinary
continuations; `test_reportRecallSuite` scores whether context the user did not type (earlier field
text, screen OCR, clipboard) actually reaches the completion. Run either with:

```bash
xcodebuild test -project Ghostype.xcodeproj -scheme Ghostype -destination 'platform=macOS' \
  -only-testing:GhostypeTests/LlamaSuggestionEvalTests/test_reportRecallSuite \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) RUN_LLAMA_EVAL' \
  CODE_SIGNING_ALLOWED=NO -configuration Release ENABLE_TESTABILITY=YES \
  -derivedDataPath build/DerivedData
```

Quote latency only from a Release build; Debug inflates per-token Swift work by an order of magnitude.
Any change to prompt content, context budgets, sampling, or the model should be justified with a
before/after on both suites over identical cases.

The dev app is a SEPARATE target and scheme, `Ghostype Dev` (product `Ghostype Dev.app`). Building the
`Ghostype` scheme leaves the dev bundle stale, so build the dev app explicitly and confirm the binary
timestamp moved before testing against it:

```bash
xcodebuild -project Ghostype.xcodeproj -scheme "Ghostype Dev" -configuration Release \
  -destination 'platform=macOS' build -derivedDataPath build/DerivedData
```

Ghost placement changes are verified against the pixels the user sees, not against log counts: type
a fragment at the end of a field, capture the ghost, accept it, capture the host's own rendering of the
same words, and compare the two, the ghost's dx/dy in points per line. A placement fix is done when
every host checked (TextEdit, a Chrome contenteditable, an Obsidian note with one wrapped paragraph and
with several) stays within about 0.2pt on every line; a change that helps one host and moves another
is a regression even when its own log counters improve.

Run targeted tests for changed pure logic when available. If validation fails, report the exact
failure and distinguish a successful build-for-testing step from actual test execution.

## Git And Worktree Safety

- The worktree may already contain user edits. Never revert unrelated changes.
- Before editing, inspect `git status -sb` and the relevant files.
- Keep commits scoped. Do not silently include unrelated dirty files.
- Avoid destructive commands such as `git reset --hard` or `git checkout --` unless the user
  explicitly asks for that operation.
