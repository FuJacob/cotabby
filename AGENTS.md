# Cotabby Codex Instructions

## Project Identity

Cotabby is a macOS menu bar app for on-device inline autocomplete. The core loop is:

1. Track the currently focused editable field through Accessibility.
2. Monitor global keyboard input without stealing focus.
3. Decide whether the field, permissions, settings, and runtime are eligible.
4. Build an autocomplete request from the focused text context and optional visual context.
5. Generate locally through Apple Intelligence or llama.cpp.
6. Normalize the model output into a short continuation.
7. Render ghost text near the caret.
8. Insert accepted chunks when the user presses `Tab` while keeping the remaining tail alive.

Privacy and local-first behavior matter. Do not introduce hosted API dependencies unless the user
explicitly asks for that direction.

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

- `Cotabby/App/`: app entrypoint, composition root, lifecycle wiring, and coordinators.
- `Cotabby/UI/`: SwiftUI/AppKit presentation: settings, onboarding, menu views, overlays, and
  visual affordances.
- `Cotabby/Services/`: side-effectful boundaries: Accessibility, input monitoring, text insertion,
  screenshots/OCR, visual context, llama runtime, permissions, downloads, updates, and launch
  services.
- `Cotabby/Models/`: shared value types, settings snapshots, states, domain models, and protocol
  contracts.
- `Cotabby/Support/`: pure helper logic, prompt rendering, availability rules, normalization,
  reconciliation, geometry helpers, and low-level bridging utilities.
- `CotabbyTests/`: unit and microbench tests. Prefer testing pure `Support/` and `Models/` logic
  when possible.
- `CotabbyInference`: the llama.cpp wrapper, consumed as a SwiftPM package
  (`github.com/FuJacob/cotabbyinference`, pinned to `main`) rather than vendored in-tree.

## App Ownership

Start here when you need to understand lifecycle:

1. `Cotabby/App/Core/CotabbyApp.swift`
2. `Cotabby/App/Core/AppDelegate.swift`
3. `Cotabby/App/Core/CotabbyAppEnvironment.swift`

`CotabbyAppEnvironment` builds the long-lived dependency graph once. `AppDelegate` starts, stops,
and wires cross-subsystem subscriptions. SwiftUI views should observe objects from that graph
rather than creating services directly.

This ownership rule prevents duplicate Accessibility observers, duplicate input monitors, runtime
reload races, and mismatched settings state.

## Suggestion Pipeline

Read the coordinator in this order:

1. `Cotabby/App/Coordinators/SuggestionCoordinator.swift`
2. `Cotabby/App/Coordinators/SuggestionCoordinator+Lifecycle.swift`
3. `Cotabby/App/Coordinators/SuggestionCoordinator+Input.swift`
4. `Cotabby/App/Coordinators/SuggestionCoordinator+Prediction.swift`
5. `Cotabby/App/Coordinators/SuggestionCoordinator+Acceptance.swift`

The coordinator owns orchestration and user-facing state. It should not absorb every rule. Prefer:

- `SuggestionRequestFactory` for pure request construction
- `SuggestionAvailabilityEvaluator` for pure gating decisions
- `SuggestionSessionReconciler` for acceptance and active-tail reconciliation
- `SuggestionTextNormalizer` for backend-independent output cleanup
- `SuggestionWorkController` for generation task identity/cancellation
- `SuggestionInteractionState` for active suggestion session storage

This split matters because autocomplete is a state machine. Pure rules are easier to test and reason
about than coordinator mutations.

## Focus And Accessibility

Focus and geometry live in:

- `FocusTracker`: observes focus/value/selection changes and publishes snapshots.
- `FocusSnapshotResolver`: reduces raw AX elements into Cotabby-supported focus snapshots.
- `AXTextGeometryResolver`: resolves caret and input geometry.
- `AXHelper`: low-level Accessibility/Core Foundation helper calls.
- `FocusModels`: pure focus values, identities, capabilities, and debug inspection data.

Accessibility data is eventually consistent and app-specific. Browser editors, Electron apps,
native AppKit fields, and secure fields expose different AX shapes. Preserve stale-result guards,
`focusChangeSequence`, and capability checks unless the change explicitly replaces them.

## Visual Context And OCR

Visual context currently flows through:

- `VisualContextCoordinator`: field-scoped visual-context session lifecycle.
- `ScreenshotContextGenerator`: screenshot -> OCR -> `OCRTextHygiene` cleanup -> bounded excerpt.
- `WindowScreenshotService`: captures the relevant window or region.
- `ScreenTextExtractor`: Vision OCR extraction, carrying per-line recognition confidence.
- `OCRTextHygiene`: pure cleanup of raw OCR (drops low-confidence lines and chrome noise). There is
  no model summarization step; a base model conditions fine on cleaned raw context.
- `VisualContextModels`: configuration, status, and excerpt values.

Do not put raw screenshots, unbounded OCR dumps, or noisy AX tree text directly into prompts.
Normalize, bound, and mark unavailable states explicitly. Screen Recording permission is separate
from Accessibility and Input Monitoring.

## Runtime And Prompting

Runtime generation is split by responsibility:

- `SuggestionEngineRouter`: selects Apple Intelligence vs Open Source.
- `FoundationModelSuggestionEngine`: Apple on-device generation path.
- `LlamaSuggestionEngine`: request-to-prompt, llama result handling, and cache reset handoff.
- `LlamaRuntimeManager`: UI-facing runtime state, model selection, warmup, and lifecycle control.
- `LlamaRuntimeCore`: serialized actor around mutable llama.cpp pointers, prompt tokenization,
  KV-cache reuse, sampling, an optional deterministic constrained decoder
  (`runConstrainedDecode`, gated behind the default-off `cotabbyConstrainedDecoderEnabled`), and
  shutdown.
- `BaseCompletionPromptRenderer`: prompt construction for the Open Source path. The llama models are
  now *base* (non-instruct) GGUFs, so this renders a pure text continuation: no instruction preamble,
  custom rules and context fold into a short conditioning preface (a base model conditions on
  description, it does not obey commands), sections are character-budgeted via `PromptSectionBudget`,
  and the caret prefix comes last. `FoundationModelPromptRenderer` stays instruct-shaped because
  Apple's Foundation Models path gives us a first-class instructions channel.

Keep llama.cpp pointer work serialized inside `LlamaRuntimeCore`. The manager should publish state;
the core should own native correctness.

## UI And Overlays

- `OverlayController` owns the ghost-text panel lifecycle and positioning.
- `SuggestionOverlayPresenter` decides whether a suggestion should be shown or hidden.
- `ActivationIndicatorController` owns the optional caret/field-edge indicator.
- `FocusDebugOverlayController` is for developer visibility and should stay gated behind debug
  options, not normal user settings.
- Settings panes (under `Cotabby/UI/Settings/Panes/`) and onboarding views should remain
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

Cotabby has a structured logging system built for AI-assisted debugging. During development the app
is launched with `-cotabby-debug`, which enables on-disk JSONL sinks in addition to the always-on
Console.app stream.

**Log file locations** (only populated when `-cotabby-debug` is set):

- `~/Library/Logs/Cotabby/cotabby.jsonl` — main event stream. One JSON object per line, with all
  metadata flattened as top-level fields so it can be filtered with `jq`.
- `~/Library/Logs/Cotabby/llm-io.jsonl` — full LLM prompts and completions, one record per
  generation. Shares `request_id` with the main log so a single suggestion can be joined across
  files.
- `~/Desktop/cotabby-ax-dump.txt` — most recent Chrome AX tree snapshot. Overwritten on each
  Chrome focus change (debounced by focused-element identity).
- Rotated previous logs: `*.jsonl.1` (one-step rotation when a file exceeds 10 MB).

**Correlation IDs.** Every prediction gets a `request_id` like `req_a3f9k2lq`, stamped on every log
line touching that request (coordinator state transitions, router selection, engine generation, LLM
I/O capture). Pull a complete history of one suggestion:

```bash
jq 'select(.request_id == "req_a3f9k2lq")' ~/Library/Logs/Cotabby/cotabby.jsonl
jq 'select(.request_id == "req_a3f9k2lq")' ~/Library/Logs/Cotabby/llm-io.jsonl
```

**Useful `jq` recipes:**

```bash
# Recent errors across the app
jq 'select(.level == "error")' ~/Library/Logs/Cotabby/cotabby.jsonl

# Llama generations slower than 500 ms
jq 'select(.engine == "llama" and .latency_ms > 500)' ~/Library/Logs/Cotabby/llm-io.jsonl

# Coordinator state transitions
jq 'select(.category == "suggestion" and .stage != null)' ~/Library/Logs/Cotabby/cotabby.jsonl

# Runtime model load/decode events
jq 'select(.category == "runtime")' ~/Library/Logs/Cotabby/cotabby.jsonl
```

**Symptom → category map:**

- Ghost text didn't appear → `suggestion` + `focus`
- Wrong text inserted → look up the request in `llm-io.jsonl`, then walk `suggestion` for
  acceptance
- Model won't load / decode fails → `runtime` + `models`
- Permission dialog loop → `app` (permission state transitions)
- Chrome-specific weirdness → start with `~/Desktop/cotabby-ax-dump.txt`, then `focus`
- Wrong backend chosen → `suggestion` router selection log (`engine`, `fallback_engine`)

**Console.app fallback** (when `-cotabby-debug` wasn't set):

```bash
log show --predicate 'subsystem == "com.cotabby.app"' --last 10m
log stream --predicate 'subsystem == "com.cotabby.app"' --level debug
```

**Rule of thumb.** When a user reports a bug, first `tail` / `jq` the relevant file with the
symptom → category map. Do not ask the user to re-explain symptoms before checking the logs.

## Validation

Use the narrowest meaningful validation first, then broaden if the change touches shared behavior.
Common commands:

```bash
xcodebuild -project Cotabby.xcodeproj -scheme Cotabby -destination 'platform=macOS' build \
  -derivedDataPath build/DerivedData
xcodebuild -project Cotabby.xcodeproj -scheme Cotabby -destination 'platform=macOS' build-for-testing \
  -derivedDataPath build/DerivedData
```

Always pass `-derivedDataPath build/DerivedData` so the output lands in the repo-scoped `build/`
directory (already gitignored) instead of accumulating under
`~/Library/Developer/Xcode/DerivedData/Cotabby-*`, where every build leaves a fresh multi-GB module
cache and SwiftPM checkout that nothing trims. When a task is done and the artifacts are no longer
needed, `rm -rf build/DerivedData` before reporting completion.

Run targeted tests for changed pure logic when available. If `xcodebuild test` fails locally because
of app-hosted test bundle signing or Team ID mismatch, report the exact failure and still provide the
successful build/build-for-testing result.

## Git And Worktree Safety

- The worktree may already contain user edits. Never revert unrelated changes.
- Before editing, inspect `git status -sb` and the relevant files.
- Keep commits scoped. Do not silently include unrelated dirty files.
- Avoid destructive commands such as `git reset --hard` or `git checkout --` unless the user
  explicitly asks for that operation.
