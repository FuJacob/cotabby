# Claude Instructions for Tabby

Tabby is a community-driven open-source macOS menu bar app that provides
on-device inline autocomplete in any text field. It watches Accessibility focus,
monitors global input, generates a local continuation through Apple Intelligence
or llama.cpp, renders ghost text near the caret, and inserts accepted text when
the user presses `Tab`.

This is a production app with real users and external contributors. Treat every
change as shipping to end users, not as an exercise.

## How To Work In This Repo

- Read the relevant subsystem before editing. Tabby is stateful, permission-heavy,
  and tied to macOS Accessibility behavior, so guessing usually creates regressions.
- Talk through architecture before coding when ownership, lifecycle, or async
  cancellation is unclear.
- Diagnose failures step by step before touching code. Many bugs come from stale
  focus snapshots, AX timing, permission state, runtime lifecycle, or cancellation.
- Keep changes narrow. Prefer pure helpers in `Support/` before changing services,
  coordinators, or SwiftUI views.
- Protect the user's worktree. Do not revert unrelated dirty files.

## Project Map

- `tabby/App/`: app lifecycle, dependency construction, and coordinators.
- `tabby/UI/`: SwiftUI/AppKit presentation such as settings, onboarding, overlays,
  and menu-facing state.
- `tabby/Services/`: side-effectful boundaries: Accessibility, input monitoring,
  screenshots/OCR, llama runtime, permissions, downloads, updates, and insertion.
- `tabby/Models/`: shared value types, settings snapshots, state machines, and
  protocol contracts.
- `tabby/Support/`: pure rules and low-level helper logic that should be easy to
  test.
- `tabbyTests/`: focused tests for prompt rendering, request building, availability,
  runtime behavior, and pure state transitions.

## Key Subsystems

- App ownership starts in `TabbyAppEnvironment` and `AppDelegate`. These construct
  and retain the long-lived services. SwiftUI views should observe this graph,
  not recreate service objects.
- The suggestion state machine lives in `SuggestionCoordinator` plus its extension
  files: lifecycle, input, prediction, and acceptance. Keep pure rules out of the
  coordinator when they can live in `Support/`.
- Focus comes from `FocusTracker`, `FocusSnapshotResolver`, `AXTextGeometryResolver`,
  and `AXHelper`. Treat AX data as eventually consistent and app-specific.
- Visual context flows through `VisualContextCoordinator`,
  `ScreenshotContextGenerator`, `ScreenTextExtractor`, `WindowScreenshotService`,
  and `LlamaVisualContextSummarizer`.
- Runtime generation flows through `SuggestionEngineRouter`,
  `FoundationModelSuggestionEngine`, `LlamaSuggestionEngine`,
  `LlamaRuntimeManager`, and the serialized `LlamaRuntimeCore` actor.

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
- New test files in `tabbyTests/` must be manually registered in
  `tabby.xcodeproj/project.pbxproj` (the `tabby/` source group auto-discovers
  files, but `tabbyTests/` uses manual PBXGroup entries).
- Run SwiftLint before pushing: `swiftlint lint --quiet`. The project config is
  in `.swiftlint.yml` (line length 140/200, trailing commas disallowed).
- Wiki lives at https://github.com/FuJacob/tabby/wiki for contributor onboarding.

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

## Validation

Prefer the narrowest useful validation first, then broaden when the change touches
shared behavior:

```bash
xcodebuild -project tabby.xcodeproj -scheme tabby -destination 'platform=macOS' build
xcodebuild -project tabby.xcodeproj -scheme tabby -destination 'platform=macOS' build-for-testing
```

Run targeted tests when possible. If app-hosted tests fail because of local signing
or Team ID mismatch, report the exact failure and still run `build-for-testing`.
