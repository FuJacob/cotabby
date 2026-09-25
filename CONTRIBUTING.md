# Contributing To CoHamster

Thanks for helping improve CoHamster. This guide is the contributor entry point for local setup,
validation, and codebase orientation.

CoHamster is a macOS menu bar app that provides on-device inline autocomplete in other apps. The repo
is split by responsibility so contributors can make small, reviewable changes without spreading
platform-specific behavior across unrelated layers.

Please read and follow the [Code of Conduct](CODE_OF_CONDUCT.md) before participating.

## Before You Start

- Read [README.md](README.md) for the product overview and end-user setup.
- Read [ARCHITECTURE.md](ARCHITECTURE.md) before changing the suggestion pipeline, runtime
  lifecycle, or Accessibility behavior.
- Check for an existing issue or open one before starting substantial work.
- Prefer small, atomic PRs with a single clear objective. Large mixed-purpose changes are harder to
review, validate, and revert safely.
- Before implementing a change, make sure you can clearly explain:
   1. The problem being solved
   2. Why the current behavior is insufficient
   3. Why the proposed approach fits the existing architecture

## Development Prerequisites

You need:

- macOS 14.0 or later for running the app and tests. Apple Intelligence runtime work requires
  macOS 26 or later.
- Xcode with Command Line Tools installed.
- An Apple ID added to Xcode (Settings > Accounts) if you want to launch the app from the IDE. A
  free account is enough; the paid Apple Developer Program is not required for local development.
  Contributors outside CoHamster's default development team run `scripts/dev-setup.sh` once to
  configure a local override (see Local Setup).
- SwiftLint for local lint checks. CI installs it with Homebrew when needed.
- XcodeGen if you need to change the project structure (targets, build settings, dependencies,
  or scheme). Install it with `brew install xcodegen`. CI installs it the same way.

Apple Silicon is strongly recommended for local model-runtime work.

## Local Setup

Maintainers can use the [Fastlane pipeline](fastlane/README.md) for signed build/launch,
verification, and packaging: `bundle exec fastlane mac dev` or `bundle exec fastlane mac verify`.
Its guide covers Ruby installation and credentials. The Xcode-based contributor setup below
remains available for contributors using their own development team.

Clone the repo and open the project. If your Apple ID is not on CoHamster's development team, run the
one-time signing setup first:

```sh
git clone https://github.com/mc-hamster/CoHamster.git CoHamster
cd CoHamster
scripts/dev-setup.sh
scripts/prepare_cohamster_workspace.sh
open build/cohamster-dependencies/CoHamster.xcworkspace
```

The committed `Config/Signing.xcconfig` defaults to CoHamster's development team, which lets team
members build immediately without Xcode modifying the generated project. `scripts/dev-setup.sh`
writes a gitignored `Config/Signing.local.xcconfig` with a contributor's own Apple Development team
id; that local value overrides the shared default and persists across pulls and project
regeneration. If you have not added an Apple ID to Xcode yet, do that first under Settings >
Accounts (a free account is enough), then re-run the script. To set the team by hand instead, copy
`Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig`, or pass it explicitly:
`DEVELOPMENT_TEAM=XXXXXXXXXX scripts/dev-setup.sh`.

You do not need a paid Apple Developer account to build or run CoHamster locally; a free personal
team can sign and launch it. The paid program is only needed to distribute notarized builds.

For everyday local work, use the **CoHamster** scheme, whose Run action uses Debug. Development is
one configuration of CoHamster: the app name, bundle identity, preferences, and model storage match
Release. Debug overlays default off and can be enabled live under Settings > General > Development.
The scheme enables diagnostic logging with `-cotabby-debug` independently. See [Run](#run).

## The Xcode Project Is Generated

`CoHamster.xcodeproj` is generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen).
It is committed to the repo so contributors do not need XcodeGen for ordinary source changes,
but **`project.yml` is the source of truth**.

Source files under `Cotabby/` and `CotabbyTests/` are auto-discovered by folder, so adding a new
file (including a new test) needs no project edit — just create it and regenerate. Only structural
changes (targets, build settings, package dependencies, scheme) require editing `project.yml`.

After any structural change, regenerate and commit the result:

```sh
xcodegen generate
```

CI runs the `XcodeGen` workflow on every PR and fails if the committed `CoHamster.xcodeproj` differs
from what `project.yml` produces. If that check is red, run `xcodegen generate` and commit the diff.
Avoid hand-editing the project in Xcode without mirroring the change into `project.yml`.

## How To Navigate The Repo

Start with these boundaries:

- `Cotabby/App/`: app lifecycle, composition root, and top-level coordinators
- `Cotabby/UI/`: SwiftUI presentation and menu/settings surfaces
- `Cotabby/Services/`: OS integrations, async work, permissions, and runtime boundaries
- `Cotabby/Models/`: shared value types, state snapshots, and protocol contracts
- `Cotabby/Support/`: pure rules, prompt helpers, normalization, and low-level utilities

Read [SOURCE_LAYOUT.md](SOURCE_LAYOUT.md) for the complete responsibility map. Swift folders do not
create namespaces, so nested folders exist for human navigation: keep a small cohesive subsystem
flat, and introduce a child folder only when at least two files form a stable, predictably named
responsibility. Put a direct unit test under the matching `CotabbyTests/` responsibility whenever
possible.

If you are changing behavior, prefer this order:

1. Pure logic in `Support/`
2. Side-effectful boundaries in `Services/`
3. Orchestration in `App/`
4. Presentation in `UI/`

That separation keeps behavior easier to test and reduces regressions in Accessibility-heavy code.

## Build

For a local compile check:

```sh
xcodebuild \
  -workspace build/cohamster-dependencies/CoHamster.xcworkspace \
  -scheme CoHamster \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

`CODE_SIGNING_ALLOWED=NO` keeps the build command usable on machines that do not have the project
owner's signing certificate. Use the shared team or your gitignored local override when you need to
launch the app locally.

## Run

From Xcode:

1. Select the **CoHamster** scheme (its Run action uses Debug).
2. Choose your Mac as the run destination and quit any already-running CoHamster instance.
3. Build and run. The app is still named "CoHamster" and uses its existing settings and models.
4. Complete onboarding if this is your first launch.
5. Grant **Accessibility** and **Input Monitoring** to "CoHamster" when prompted, and optionally
   **Screen Recording** for visual context. These map to the features in
   [README.md](README.md#permissions).
6. Pick Apple Intelligence if available, or use the Open Source engine with a downloaded GGUF
   model.

Keep the signing identity consistent with the CoHamster build you granted permissions to so
macOS can recognize it across rebuilds. If a permission reads as enabled but the app behaves as if it is not (common after
switching signing identity, or when an earlier unsigned build left a stale entry), reset it and
grant again:

```sh
tccutil reset Accessibility org.mchamster.cotabby
tccutil reset ListenEvent org.mchamster.cotabby
```

Then toggle the app back on in System Settings > Privacy & Security. Avoid ad-hoc "Sign to Run
Locally" builds for real testing: macOS ties the Accessibility grant to the code signature, so an
ad-hoc build changes identity on every rebuild and loses the grant each time.

If a suggestion does not appear or the overlay is misplaced, start with the focus and geometry
sections in [ARCHITECTURE.md](ARCHITECTURE.md) before changing coordinator logic.

## Test

Run the unit test suite:

```sh
xcodebuild test \
  -workspace build/cohamster-dependencies/CoHamster.xcworkspace \
  -scheme CoHamster \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

The CI test workflow uses the same macOS deployment target as the app, so tests should not require
a macOS 26 runner unless a future change raises the app baseline again.

### Local Autocomplete Evaluations

The ordinary test suite checks deterministic request, cache, token-boundary, and scoring rules
without downloading a model. Two opt-in suites exercise an actual local GGUF:

- `LlamaSuggestionEvalTests` scores isolated writing contexts after normalization and display guards.
- `LlamaTypingSessionEvalTests` replays fixed editor snapshots for unfinished words, backspaces,
  rapid word-acceptance opportunities, paragraphs/lists, and edits before existing text. It compares
  cold versus prewarmed prompt caches, each with streaming disabled and enabled.

Both suites use sampler seed `42`, reported in the test output (and the typing report's JSON), so
baseline comparisons keep the same random sequence along with the same input text.

The typing suite records the time from scripted input to the first display-eligible candidate, the
first reference-matching word, and final output. It also records revisions, withdrawn suggestions,
late callbacks, cancellation drain time, and elapsed cancelled requests that produced no useful
word. That last value includes queueing and is **not** a measure of CPU/GPU time. Missing useful
output remains missing in the report rather than becoming a zero-millisecond success.

The replay uses production request construction, generation, normalization, and streaming guards,
with a fixed debounce. It does not measure Accessibility delivery, adaptive debounce, overlay
layout, or the coordinator's reuse of an accepted tail. A scripted Tab counts an acceptance
opportunity only when the displayed next-word chunk matches the intended insertion; the next
snapshot stays fixed regardless, so model comparisons receive the same text. These are not actual
user acceptance rates. The real app's debug-only `first-presentation` events separately report
`input_to_first_presentation_ms`: input to the controller accepting its first presentation state
update, including a reused tail. This excludes fade animation and screen compositor timing and
does not determine whether the text is useful.

Use Release builds for latency comparisons; Debug timings mostly measure unoptimized Swift work.
First compile the opt-in suites:

```sh
xcodebuild build-for-testing \
  -workspace build/cohamster-dependencies/CoHamster.xcworkspace \
  -scheme CoHamster \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  ENABLE_TESTABILITY=YES \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) RUN_LLAMA_EVAL' \
  CODE_SIGNING_ALLOWED=NO
```

By default the suites use the model available in CoHamster's normal runtime directory. To evaluate
a repo-local or other explicitly chosen model without changing app settings, set
`COTABBY_EVAL_MODEL_PATH` in the generated **test process environment**. Exporting a shell variable
before `xcodebuild` does not forward it into the app-hosted test runner. Find the generated run
file, then substitute its exact path and your model path below:

```sh
rg --files build/DerivedData/Build/Products | rg '\.xctestrun$'

# Replace the SDK/architecture filename with the one emitted by your build.
eval_run_path='build/DerivedData/Build/Products/CoHamster_macosx27.0-arm64.xctestrun'
eval_model_path='/absolute/path/to/model.gguf'
/usr/libexec/PlistBuddy \
  -c "Add :CotabbyTests:EnvironmentVariables:COTABBY_EVAL_MODEL_PATH string $eval_model_path" \
  "$eval_run_path"

xcodebuild test-without-building \
  -xctestrun "$eval_run_path" \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  -only-testing:CotabbyTests/LlamaTypingSessionEvalTests
```

Use `Set` instead of `Add` when updating an existing override. The current scheme emits xctestrun
format 1, with `CotabbyTests.EnvironmentVariables`; if using a test plan that emits format 2,
set the same variable in that target's `EnvironmentVariables` under `TestConfigurations` and
`TestTargets`. Select `LlamaSuggestionEvalTests` instead to run the isolated-context suite. An
explicit invalid model fails the evaluation; an absent default model skips it with a hint.

JSON reports are written under the gitignored `build/eval/` directory. Preserve a baseline before
another run overwrites the same model's report, and compare the same model file, quantization,
build configuration, settings, and hardware. The synthetic reference continuations are not
exhaustive; inspect reported mismatches before treating a score change as a regression. The timing
instrumentation stores no prompts or typed text. Eval reports contain their synthetic fixtures and
generated suggestions; the existing `-cotabby-debug` LLM I/O log still records prompts/completions
as documented in [AGENTS.md](AGENTS.md). No new background writing-history collection is enabled.

### Paired CotabbyInference Changes

CoHamster currently uses the pinned CotabbyInference source plus
`patches/cotabbyinference-mchamster.patch`. The plain remote package does not yet expose all the
APIs used by this fork. Prepare the matching dependency and workspace before building:

```sh
scripts/prepare_cohamster_workspace.sh
```

The build commands above use this workspace to resolve the patched package. `scripts/build_and_run.sh` and the
release script do this preparation automatically. The helper verifies the existing checkout and
fails on drift instead of overwriting edits. For intentional native development, use
`python3 scripts/create-inference-workspace.py /absolute/path/to/CotabbyInference` to create a
separate local workspace. Keep generated workspaces and machine-specific paths out of commits.

After validation, remove `build/DerivedData` when its build artifacts are no longer needed. Keep
any evaluation reports or model downloads you still need separately under `build/`.

## Lint

Run SwiftLint locally:

```sh
swiftlint --reporter github-actions-logging
```

The current CI lint gate is warnings-only. Treat warnings as cleanup work, but avoid bundling
unrelated style rewrites into functional PRs.

## Debugging

The shared Xcode scheme passes `-cotabby-debug` by default in Debug builds. This enables
developer-only diagnostics:

- **Focus debug overlay**: translucent panels showing caret geometry, element bounds, focus
  polling events, and visual-context pipeline status.
- **Suggestion debug logger**: color-coded console output for each generation cycle: prompt sent,
  raw model response, and normalized output.
- **Screenshot capture**: saves OCR debug screenshots to disk when the visual-context pipeline
  runs.

To disable it, uncheck `-cotabby-debug` in the scheme's Run → Arguments tab.

## Pull Requests

Before opening or updating a PR:

- Keep the change scoped to one problem.
- Explain what changed and why.
- Link the relevant issue with `Fixes #N` or `Refs #N`.
- Include screenshots or short recordings for visible UI changes.
- Run the relevant validation command for your change:
  - build for compile-only or docs-adjacent changes
  - tests for logic or pipeline behavior
  - SwiftLint for style-sensitive edits
- Call out skipped validation explicitly.
- Keep unrelated refactors out of the PR.
- Update docs when setup, release flow, permissions, architecture, or user-facing behavior changes.

Use the repository PR template and replace every placeholder section with concrete content grounded
in the actual diff and validation output.

## CI Expectations

PRs into `main` run:

- Build: `xcodebuild` compile check
- Tests: `xcodebuild test`
- Lint: SwiftLint warnings surfaced as GitHub annotations

If CI fails because of your change, fix the root cause in the same PR. If the failure is unrelated
infrastructure noise, note that clearly in the PR description.

### Product identity

`CoHamster.xcodeproj` and its `CoHamster` scheme are generated from `project.yml`.
The Swift module and source directories remain `Cotabby` / `CotabbyTests` for source compatibility.
Debug and Release retain `org.mchamster.cotabby`, the existing preference keys, and the
`Cotabby McHamster` Application Support directory so installed fork users keep their settings,
credentials, and models. `CoHamsterDataDirectory` in `Config/CoHamsterInfo.plist` separates storage
identity from the name shown in macOS. Development uses that same identity and storage.

The repository is `mc-hamster/CoHamster`. GitHub redirects links from its previous repository name.
Brand artwork is generated from the original vector paths in `scripts/generate_brand_assets.swift`.
Run `swift scripts/generate_brand_assets.swift` from the repo root to regenerate icon sizes.
