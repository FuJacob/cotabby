# Contributing To Cotabby

Thanks for helping improve Cotabby. This guide is the contributor entry point for local setup,
validation, and codebase orientation.

Cotabby is a macOS menu bar app that provides on-device inline autocomplete in other apps. The repo
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
  Run `scripts/dev-setup.sh` once to configure signing (see Local Setup).
- SwiftLint for local lint checks. CI installs it with Homebrew when needed.
- XcodeGen if you need to change the project structure (targets, build settings, dependencies,
  or scheme). Install it with `brew install xcodegen`. CI installs it the same way.

Apple Silicon is strongly recommended for local model-runtime work.

## Local Setup

Clone the repo, configure local signing, and open the project:

```sh
git clone https://github.com/FuJacob/Cotabby.git
cd Cotabby
scripts/dev-setup.sh
open Cotabby.xcodeproj
```

`scripts/dev-setup.sh` writes a gitignored `Config/Signing.local.xcconfig` with your Apple
Development team id, so local builds sign as you. The team is deliberately not hardcoded in
`project.yml`, so the repo builds for any contributor without being on the maintainer's team. If
you have not added an Apple ID to Xcode yet, do that first under Settings > Accounts (a free
account is enough), then re-run the script. To set the team by hand instead, copy
`Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig`, or pass it explicitly:
`DEVELOPMENT_TEAM=XXXXXXXXXX scripts/dev-setup.sh`.

You do not need a paid Apple Developer account to build or run Cotabby locally; a free personal
team can sign and launch it. The paid program is only needed to distribute notarized builds.

For everyday local work, use the **Cotabby Dev** scheme rather than `Cotabby`. It builds a separate
app identity (`com.jacobfu.tabby.dev`, its own icon, auto-update disabled), so the permissions you
grant your dev build never collide with a released copy of Cotabby you have installed, and your
Accessibility grant survives rebuilds. See [Run](#run).

## The Xcode Project Is Generated

`Cotabby.xcodeproj` is generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen).
It is committed to the repo so you can clone and `open Cotabby.xcodeproj` without any extra tooling,
but **`project.yml` is the source of truth**.

Source files under `Cotabby/` and `CotabbyTests/` are auto-discovered by folder, so adding a new
file (including a new test) needs no project edit — just create it and regenerate. Only structural
changes (targets, build settings, package dependencies, scheme) require editing `project.yml`.

After any structural change, regenerate and commit the result:

```sh
xcodegen generate
```

CI runs the `XcodeGen` workflow on every PR and fails if the committed `Cotabby.xcodeproj` differs
from what `project.yml` produces. If that check is red, run `xcodegen generate` and commit the diff.
Avoid hand-editing the project in Xcode without mirroring the change into `project.yml`.

## How To Navigate The Repo

Start with these boundaries:

- `Cotabby/App/`: app lifecycle, composition root, and top-level coordinators
- `Cotabby/UI/`: SwiftUI presentation and menu/settings surfaces
- `Cotabby/Services/`: OS integrations, async work, permissions, and runtime boundaries
- `Cotabby/Models/`: shared value types, state snapshots, and protocol contracts
- `Cotabby/Support/`: pure rules, prompt helpers, normalization, and low-level utilities

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
  -project Cotabby.xcodeproj \
  -scheme Cotabby \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

`CODE_SIGNING_ALLOWED=NO` keeps the build command usable on machines that do not have the project
owner's signing certificate. Use Xcode with your own team selected when you need to launch the app
locally.

## Run

From Xcode:

1. Select the **Cotabby Dev** scheme (see [Local Setup](#local-setup) for why).
2. Choose your Mac as the run destination.
3. Build and run. The dev build is named "Cotabby Dev" and has its own menu bar icon.
4. Complete onboarding.
5. Grant **Accessibility** and **Input Monitoring** to "Cotabby Dev" when prompted, and optionally
   **Screen Recording** for visual context. These map to the features in
   [README.md](README.md#permissions).
6. Pick Apple Intelligence if available, or use the Open Source engine with a downloaded GGUF
   model.

Because the dev build signs with your own stable team, macOS remembers these grants across
rebuilds. If a permission reads as enabled but the app behaves as if it is not (common after
switching signing identity, or when an earlier unsigned build left a stale entry), reset it and
grant again:

```sh
tccutil reset Accessibility com.jacobfu.tabby.dev
tccutil reset ListenEvent com.jacobfu.tabby.dev
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
  -project Cotabby.xcodeproj \
  -scheme Cotabby \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

The CI test workflow uses the same macOS deployment target as the app, so tests should not require
a macOS 26 runner unless a future change raises the app baseline again.

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
