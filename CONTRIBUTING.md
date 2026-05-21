# Contributing To tabby

Thanks for helping improve tabby. This guide is the contributor entry point for local setup,
validation, and codebase orientation.

tabby is a macOS menu bar app that provides on-device inline autocomplete in other apps. The repo
is split by responsibility so contributors can make small, reviewable changes without spreading
platform-specific behavior across unrelated layers.

Please read and follow the [Code of Conduct](CODE_OF_CONDUCT.md) before participating.

## Before You Start

- Read [README.md](README.md) for the product overview and end-user setup.
- Read [ARCHITECTURE.md](ARCHITECTURE.md) before changing the suggestion pipeline, runtime
  lifecycle, or Accessibility behavior.
- Check for an existing issue or open one before starting substantial work.

## Development Prerequisites

You need:

- macOS 15.0 or later for running the app and tests. Apple Intelligence runtime work requires
  macOS 26 or later.
- Xcode with Command Line Tools installed.
- A local Apple development team configured in Xcode if you want to launch the signed app from the
  IDE.
- SwiftLint for local lint checks. CI installs it with Homebrew when needed.

Apple Silicon is strongly recommended for local model-runtime work.

## Local Setup

Clone the repo and open the project:

```sh
git clone https://github.com/FuJacob/tabby.git
cd tabby
open tabby.xcodeproj
```

In Xcode, select the `tabby` scheme. If you run from Xcode, set your signing team under
`Signing & Capabilities`.

## How To Navigate The Repo

Start with these boundaries:

- `tabby/App/`: app lifecycle, composition root, and top-level coordinators
- `tabby/UI/`: SwiftUI presentation and menu/settings surfaces
- `tabby/Services/`: OS integrations, async work, permissions, and runtime boundaries
- `tabby/Models/`: shared value types, state snapshots, and protocol contracts
- `tabby/Support/`: pure rules, prompt helpers, normalization, and low-level utilities

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
  -project tabby.xcodeproj \
  -scheme tabby \
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

1. Select the `tabby` scheme.
2. Choose your Mac as the run destination.
3. Build and run.
4. Complete onboarding.
5. Grant Accessibility and Input Monitoring when prompted.
6. Pick Apple Intelligence if available, or use the Open Source engine with a downloaded GGUF
   model.

If a suggestion does not appear or the overlay is misplaced, start with the focus and geometry
sections in [ARCHITECTURE.md](ARCHITECTURE.md) before changing coordinator logic.

## Test

Run the unit test suite:

```sh
xcodebuild test \
  -project tabby.xcodeproj \
  -scheme tabby \
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
