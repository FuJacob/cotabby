# Claude Instructions for Cotabby

Cotabby is a community-driven open-source macOS menu bar app that provides
on-device inline autocomplete in any text field. It watches Accessibility focus,
monitors global input, generates a local continuation through Apple Intelligence
or llama.cpp, renders ghost text near the caret, and inserts accepted text when
the user presses `Tab`.

This is a production app with real users and external contributors. Treat every
change as shipping to end users, not as an exercise.

## How To Work In This Repo

- Read the relevant subsystem before editing. Cotabby is stateful, permission-heavy,
  and tied to macOS Accessibility behavior, so guessing usually creates regressions.
- Talk through architecture before coding when ownership, lifecycle, or async
  cancellation is unclear.
- Diagnose failures step by step before touching code. Many bugs come from stale
  focus snapshots, AX timing, permission state, runtime lifecycle, or cancellation.
- Keep changes narrow. Prefer pure helpers in `Support/` before changing services,
  coordinators, or SwiftUI views.
- Protect the user's worktree. Do not revert unrelated dirty files.

## Project Map

- `Cotabby/App/`: app lifecycle, dependency construction, and coordinators.
- `Cotabby/UI/`: SwiftUI/AppKit presentation such as settings, onboarding, overlays,
  and menu-facing state.
- `Cotabby/Services/`: side-effectful boundaries: Accessibility, input monitoring,
  screenshots/OCR, llama runtime, permissions, downloads, updates, and insertion.
- `Cotabby/Models/`: shared value types, settings snapshots, state machines, and
  protocol contracts.
- `Cotabby/Support/`: pure rules and low-level helper logic that should be easy to
  test.
- `CotabbyTests/`: focused tests for prompt rendering, request building, availability,
  runtime behavior, and pure state transitions.

## Key Subsystems

- App ownership starts in `CotabbyAppEnvironment` and `AppDelegate`. These construct
  and retain the long-lived services. SwiftUI views should observe this graph,
  not recreate service objects.
- The suggestion state machine lives in `SuggestionCoordinator` plus its extension
  files: lifecycle, input, prediction, and acceptance. Keep pure rules out of the
  coordinator when they can live in `Support/`.
- Focus comes from `FocusTracker`, `FocusSnapshotResolver`, `AXTextGeometryResolver`,
  and `AXHelper`. Treat AX data as eventually consistent and app-specific.
- Visual context flows through `VisualContextCoordinator`,
  `ScreenshotContextGenerator`, `ScreenTextExtractor`, and `WindowScreenshotService`.
  OCR text is cleaned by the pure `OCRTextHygiene`; there is no model summarization step.
- Runtime generation flows through `SuggestionEngineRouter`,
  `FoundationModelSuggestionEngine`, `LlamaSuggestionEngine`,
  `LlamaRuntimeManager`, and the serialized `LlamaRuntimeCore` actor. The OSS
  (llama.cpp) path drives base models via `BaseCompletionPromptRenderer`; Apple
  Foundation Models stays instruct via `FoundationModelPromptRenderer`.

## Comments

- Comments should explain why, not what. Explain which invariant a design
  protects or which macOS/Swift pitfall it avoids.
- Prefer file-level and type-level `///` comments for new important files/types.
- Add targeted inline comments for tricky lifecycle, `@MainActor`, `Task`,
  cancellation, Accessibility/Core Foundation bridging, unsafe pointer work, and
  llama.cpp runtime state.
- Avoid comments that merely restate the next line of code.

## Contributing Workflow

- External contributors open PRs against `main`. Greptile reviews automatically.
- `Cotabby.xcodeproj` is generated from `project.yml` by XcodeGen and committed to the
  repo. `project.yml` is the source of truth. Sources under `Cotabby/` and `CotabbyTests/`
  are auto-discovered by folder, so a new file (including a new test) needs no project edit.
  Only structural changes (targets, build settings, package dependencies, scheme) require
  editing `project.yml` followed by `xcodegen generate`. The `XcodeGen` CI workflow fails the
  PR if the committed project drifts from `project.yml`.
- Run SwiftLint before pushing: `swiftlint lint --quiet`. The project config is
  in `.swiftlint.yml` (line length 140/200, trailing commas disallowed).
- Wiki lives at https://github.com/FuJacob/Cotabby/wiki for contributor onboarding.

## GitHub Automation Rules

- **No Co-Authored-By lines.** Never add `Co-Authored-By` trailers to commits.
- **PRs must use the repo template.** When creating a pull request, read
  `.github/PULL_REQUEST_TEMPLATE.md` and fill in every section (Summary,
  Validation, Linked issues, Risk / rollout notes). Do not invent your own
  format or use a generic body.
- **Issues must use the repo templates.** When opening an issue, read the
  matching template in `.github/ISSUE_TEMPLATE/` (bug_report.md or
  feature_request.md) and fill in every field. Do not invent your own format.

## Swift And macOS Expectations

- UI, AppKit, SwiftUI, and most Accessibility interactions belong on the main actor.
- CPU-heavy work, OCR, screenshots, and llama.cpp generation must not block the UI.
- Keep cancellation and stale-result handling explicit. The focused field can change
  while async work is still running.
- Use protocol contracts in `SuggestionSubsystemContracts.swift` when the coordinator
  only needs a behavior-shaped dependency.
- Do not show dev-only diagnostics as normal user settings unless the feature is
  intentionally productized.

## Debugging & Logs

Cotabby ships a structured logging system built for AI-assisted debugging. During development
the app is launched with `-cotabby-debug`, which enables on-disk JSONL sinks in addition to
the always-on Console.app stream.

**Log file locations** (only populated when `-cotabby-debug` is set):

- `~/Library/Logs/Cotabby/cotabby.jsonl` — main event stream. One JSON object per line. All
  metadata (request IDs, engine names, token counts, latencies, error reasons) is flattened
  as top-level fields so it can be filtered with `jq`.
- `~/Library/Logs/Cotabby/llm-io.jsonl` — full LLM prompts and completions, one record per
  generation. Shares `request_id` with the main log so a single suggestion can be joined
  across files.
- `~/Desktop/cotabby-ax-dump.txt` — most recent Chrome AX tree snapshot. Overwritten on each
  Chrome focus change (debounced by focused-element identity).
- Rotated previous logs: `*.jsonl.1` (one-step rotation when a file exceeds 10 MB).

**Correlation IDs.** Every prediction gets a `request_id` like `req_a3f9k2lq`, stamped on
every log line that touches that request (coordinator state transitions, router selection,
engine generation, LLM I/O capture). To pull the complete history of one suggestion:

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

**Symptom → category map** (jump straight to the right filter):

- Ghost text didn't appear → `suggestion` + `focus`
- Wrong text inserted → look up the request in `llm-io.jsonl`, then walk `suggestion` for
  acceptance
- Model won't load / decode fails → `runtime` + `models`
- Permission dialog loop → `app` (permission state transitions)
- Chrome-specific weirdness → start with `~/Desktop/cotabby-ax-dump.txt`, then `focus`
- Wrong backend chosen → `suggestion` router selection log (`engine`, `fallback_engine`)

**Console.app fallback** (when `-cotabby-debug` wasn't set or the user hasn't relaunched yet):

```bash
log show --predicate 'subsystem == "com.cotabby.app"' --last 10m
log stream --predicate 'subsystem == "com.cotabby.app"' --level debug
```

**Rule of thumb.** When a user reports a bug, first `tail` / `jq` the relevant file with the
symptom → category map. Do not ask the user to re-explain symptoms before checking the logs.
If `-cotabby-debug` clearly isn't on (no JSONL files exist), use the `log show` fallback
first; only ask for a relaunch with the flag if the OSLog stream is genuinely insufficient.

## Validation

Prefer the narrowest useful validation first, then broaden when the change touches
shared behavior:

```bash
xcodebuild -project Cotabby.xcodeproj -scheme Cotabby -destination 'platform=macOS' build \
  -derivedDataPath build/DerivedData
xcodebuild -project Cotabby.xcodeproj -scheme Cotabby -destination 'platform=macOS' build-for-testing \
  -derivedDataPath build/DerivedData
```

Always pass `-derivedDataPath build/DerivedData` so output lands in the
repo-scoped `build/` (already gitignored) instead of accumulating under
`~/Library/Developer/Xcode/DerivedData/Cotabby-*`, where every build leaves a
fresh multi-GB module cache and SwiftPM checkout that nothing trims. When a
task is done and the build artifacts are no longer needed, `rm -rf
build/DerivedData` before reporting completion.

Run targeted tests when possible. If app-hosted tests fail because of local signing
or Team ID mismatch, report the exact failure and still run `build-for-testing`.
