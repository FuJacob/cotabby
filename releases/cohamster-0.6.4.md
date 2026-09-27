# CoHamster 0.6.4

Faster prediction reuse while typing, September 24, 2026.

- On-device predictions can keep generating through matching keystrokes, so useful work is ready
  sooner when you pause. Divergent typing starts a fresh request using your current text.
- **Predict Ahead While Typing** is enabled by default in **Settings → General → Suggestions**.
  Turn it off to cancel generation on new keystrokes. This choice is saved and takes effect immediately.
- Prediction reuse works with Apple Intelligence and Open Source models. Configured endpoints keep
  their existing behavior. The separate streaming setting still controls whether partial text appears.
- Focus changes, dismissal, and acceptance invalidate obsolete work; suggestions wait for the host
  editor to confirm the typed text before appearing at the new caret.
- Apple Intelligence prompts no longer include an unrelated programming example in every request.

## Install

Download **CoHamster-0.6.4-arm64.dmg**, open it, and drag **CoHamster.app** into Applications.
Quit your existing CoHamster copy before replacing it. Requires an Apple Silicon Mac running
macOS 14 or later; Apple Intelligence requires macOS 26 and supported hardware.
The app is Developer ID signed and notarized by Apple. This is a prerelease.
Existing settings, credentials, and downloaded models remain compatible.

## Source and license

CoHamster is distributed under AGPLv3. The matching source is attached as
**CoHamster-0.6.4-source.tar.gz**, including the patched CotabbyInference source and pinned
third-party dependency sources. Build instructions are in CONTRIBUTING.md and releases/README.md.
License notices ship inside the app and DMG. Model weights are downloaded separately under their
own terms. SHA256SUMS.txt contains checksums for the download and source archive.

Validation: macOS build-for-testing succeeded; 821 tests across 75 suggestion, settings, search,
and prompting suites passed. Timing tests use a controlled engine; real-model latency varies by Mac
and model.
