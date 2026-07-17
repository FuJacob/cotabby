# Cotabby Coding-Agent Instructions

## Source of Truth

- Code and tests are the final authority for shipping behavior.
- Read `ARCHITECTURE.md` before changing lifecycle, Accessibility, input, generation, context,
  insertion, or presentation. It is the tracked ten-minute system map.
- `.internal/` may contain private, gitignored study notes in a local checkout. Use them for deeper
  navigation when present, but verify every claim against code and never make tracked documentation
  depend on them.
- When a tracked document conflicts with code, follow the code and update the stale document in the
  same change.

## Product Contract

Cotabby is a macOS menu bar agent for inline autocomplete in other applications. The core loop is:

1. Resolve a supported focused field through Accessibility.
2. Observe global keyboard input without taking focus.
3. Gate work using permissions, field capability, settings, and runtime state.
4. Build a bounded immutable request from caret text and optional context.
5. Generate through Apple Intelligence, in-process llama.cpp, or a configured OpenAI-compatible
   endpoint.
6. Normalize the result into a safe short continuation.
7. Render inline ghost text or a mirror card near the caret.
8. Reconcile typing and insert accepted chunks through configurable shortcuts.

Cotabby is local-first, not unconditionally offline. Apple Intelligence and llama.cpp run on the
Mac. The endpoint backend may send the bounded request to loopback, LAN, or public HTTPS when the
user explicitly selects it. Do not add or broaden hosted transmission without explicit user scope,
clear disclosure, and the existing privacy boundaries.

Secure and unsupported fields fail closed for generation, presentation, acceptance, and inline
commands. Do not claim they are never acquired: bounded AX context and optional visual work can
currently occur before the secure capability block. Treat that as documented privacy debt until the
acquisition boundary itself changes.

## Learning-First Collaboration

- Explain both what changed and why, including ownership, lifetime, collaborators, and data flow.
- Assume the user is learning Swift, AppKit, Accessibility, async/await, actor isolation, llama.cpp,
  and macOS app architecture.
- Teach at the file, type, and subsystem level. Call out tradeoffs when several designs are valid.
- Prefer clean boundaries over quick coupling across `App`, `UI`, `Services`, `Models`, and
  `Support`.
- Comments should explain an invariant, ownership rule, macOS quirk, or failure mode. Do not add
  comments that merely narrate the next line.

## Repository and Ownership Map

- `Cotabby/App/`: composition root, lifecycle wiring, and coordinators.
- `Cotabby/UI/`: SwiftUI views for menus, settings, onboarding, overlays, and inline features.
- `Cotabby/Services/`: side effects and OS/runtime boundaries for focus, input, insertion, visual
  capture, inference, model management, permissions, power, presentation, spelling, and updates.
- `Cotabby/Models/`: domain values, settings, states, and protocol contracts.
- `Cotabby/Support/`: deterministic policy, prompting, normalization, reconciliation, geometry,
  sanitization, logging, and low-level bridging helpers.
- `CotabbyTests/`: unit and microbench tests. Prefer testing pure Models and Support behavior.
- `CotabbyInference`: external SwiftPM llama.cpp wrapper pinned to its `main` branch.
- `project.yml`: XcodeGen source of truth. `Cotabby.xcodeproj` is generated and committed.

For app ownership, read in order:

1. `Cotabby/App/Core/CotabbyApp.swift`
2. `Cotabby/App/Core/AppDelegate.swift`
3. `Cotabby/App/Core/CotabbyAppEnvironment.swift`

`CotabbyAppEnvironment` constructs and retains one app-lifetime dependency graph. `AppDelegate`
starts and stops side effects and owns process-lifecycle subscriptions. Views observe shared objects;
they do not create process-wide services. Construction does not imply startup, production services
do not start in the XCTest host, and shutdown stops new work before native teardown.

For the suggestion state machine, read:

1. `SuggestionCoordinator.swift`
2. `SuggestionCoordinator+Lifecycle.swift`
3. `SuggestionCoordinator+Input.swift`
4. `SuggestionCoordinator+Prediction.swift`
5. `SuggestionCoordinator+Acceptance.swift`

Keep orchestration in the coordinator and pure rules in focused owners such as
`SuggestionAvailabilityEvaluator`, `SuggestionRequestFactory`, `SuggestionSessionReconciler`, and
`SuggestionTextNormalizer`. `SuggestionWorkController` owns work identity and cancellation;
`SuggestionInteractionState` owns the active suggestion session.

## Reliability and Concurrency Rules

- Treat AX state as eventually consistent and application-specific. Polling is authoritative.
- Revalidate work ID, focus/content signatures, settings continuity, and session state after every
  await that can outlive them. AX element identity alone is not a stale-result guard.
- A generation request is immutable once asynchronous work starts. Engines never reach back into
  live editor state.
- Steady input observation is listen-only. Consume a key only after the owning feature succeeds;
  stale or rejected interception must fail open to the host application.
- Keep overlay text equal to the active session tail before acceptance. Host publication after
  insertion is reconciled, never assumed.
- Use Unicode key events for short ordinary insertion, the IME-safe paste path during active
  composition, and preserve clipboard contents unless newer user clipboard activity wins.
- Bound and sanitize every context source before request assembly. Never put raw screenshots,
  unbounded OCR, or noisy AX dumps into prompts.
- Use `@MainActor` for UI, AppKit, published state, and most AX access. OCR, capture, downloads,
  model loading, endpoint calls, and generation must not block it.
- Use actors or explicit serialization for mutable non-UI state. `LlamaRuntimeCore` is not a Swift
  actor: its native pointers, cache/decode state, and shutdown lifecycle are protected by explicit
  locks and a condition. Do not weaken that serialization.
- Context reset must prevent cache data from crossing interaction boundaries. Switching away from
  the Open Source engine must release native runtime resources.
- Endpoint credentials belong in Keychain. Preserve rejection of insecure public HTTP.
- Cancellation is expected lifecycle behavior, not automatically a backend failure.

## Change Strategy

Prefer this dependency direction when changing behavior:

1. Pure policy in `Support/`
2. Domain values and contracts in `Models/`
3. Side-effectful boundaries in `Services/`
4. Orchestration in `App/`
5. Presentation in `UI/`

This is not a requirement to touch every layer. It prevents deterministic rules from being buried in
stateful coordinators or views. Prefer narrow protocols from `SuggestionSubsystemContracts.swift`
when a coordinator needs behavior rather than a concrete service.

Treat Core Foundation, AX bridging, and native pointers as unsafe boundaries. Explain ownership,
casting, lifetime, cancellation, and failure handling where they are not obvious.

## Debugging and Logs

When a bug is reported, inspect existing diagnostics before asking the user to reproduce or
re-explain it. `-cotabby-debug` enables privacy-sensitive JSONL and capture artifacts; the default
log floor is `.info`, while debug mode raises it to `.trace`. `COTABBY_LOG_LEVEL` overrides the floor.

- Production: `~/Library/Logs/Cotabby/cotabby.jsonl` and `llm-io.jsonl`
- Dev identity: `~/Library/Logs/Cotabby Dev/cotabby.jsonl` and `llm-io.jsonl`
- Chrome AX snapshot: `~/Desktop/cotabby-ax-dump.txt`
- Visual debug captures: `~/Desktop/cotabby-debug-screenshots/`

Use `request_id` to join suggestion and LLM-I/O events. Start with `focus` for field/geometry issues,
`suggestion` for state/acceptance, `runtime` and `models` for backend failures, and `app` for
permissions/lifecycle. If JSONL files do not exist, use unified logging:

```bash
log show --predicate 'subsystem == "com.cotabby.app"' --last 10m
log stream --predicate 'subsystem == "com.cotabby.app"' --level debug
```

The `log` display level cannot recover `.debug` or `.trace` events that Cotabby's emission floor
already skipped.

## Validation

Use the narrowest meaningful test first, then broaden for shared behavior:

```bash
xcodebuild -project Cotabby.xcodeproj -scheme Cotabby -destination 'platform=macOS' build \
  -derivedDataPath build/DerivedData
xcodebuild -project Cotabby.xcodeproj -scheme Cotabby -destination 'platform=macOS' build-for-testing \
  -derivedDataPath build/DerivedData
```

- Run focused tests for changed pure logic and `swiftlint lint --quiet` for Swift changes.
- If app-hosted tests fail because of signing or Team ID mismatch, report the exact failure and the
  successful build/build-for-testing result.
- Remove `build/DerivedData` after the artifacts are no longer needed.
- Sources are recursively discovered. Edit `project.yml` and run `xcodegen generate` only for
  structural target, build-setting, package, or scheme changes. CI regenerates the project and fails
  on drift.

## Documentation Maintenance

- Update `ARCHITECTURE.md` when the ten-minute mental model, ownership, data flow, privacy boundary,
  backend set, or reliability invariant changes.
- Keep links resolvable and name concrete owners. Do not document planned behavior as shipping.
- Update setup, release, permission, and contributor docs when their contracts change.
- If private `.internal/` guides exist, update the affected guide for local study, but remember those
  files are gitignored and cannot carry a public PR's explanation.

## Git and GitHub Safety

- Inspect `git status -sb` and relevant diffs before editing. Preserve unrelated worktree changes.
- Stage only intended paths and keep commits scoped. Never use destructive reset/checkout commands
  unless the user explicitly requests them.
- Do not add `Co-Authored-By` trailers.
- Pull requests must use `.github/PULL_REQUEST_TEMPLATE.md` and report actual validation.
- Issues must use the matching template under `.github/ISSUE_TEMPLATE/`.
