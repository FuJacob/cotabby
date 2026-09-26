# CoHamster 0.6.5

Version consistency and faster Apple Intelligence predictions, September 24, 2026.

- Local builds and release downloads now share version **0.6.5 (2026092403)**. Previously, a local
  build could display **1.0 (1)** even when GitHub releases used the 0.6.x version series.
  Packaging rejects mismatched version arguments and checks the final app metadata.
- Apple Intelligence immediately restarts an unseen prediction when typing advances, removing the
  extra catch-up wait before generating for the current caret. Open Source retains its token grace.
- Predictions missing a space between two known words can now appear and be accepted correctly.
  Valid word joins, unknown vocabulary, and incomplete streamed words keep their existing safeguards.

Live automated typing in TextEdit with Apple Intelligence measured a median of **513 ms → 424 ms**
across six matched pauses where both builds showed predictions. Prediction coverage was **6/10 →
10/10** valid pauses. This is a small fixed-phrase sample; it measures overlay submission, not screen
refresh, and some predictions still took 665–724 ms. See the checked-in
`benchmarks/live-typing/2026-09-24-apple-intelligence/` report for methodology and exclusions.

## Install

Download **CoHamster-0.6.5-arm64.dmg**, quit CoHamster, and drag **CoHamster.app** into Applications.
Requires an Apple Silicon Mac running macOS 14 or later; Apple Intelligence requires macOS 26 and
supported hardware. This is a Developer ID signed, Apple-notarized prerelease.
Existing preferences, credentials, and downloaded models remain compatible.

## Source and license

The matching **CoHamster-0.6.5-source.tar.gz** includes app source, the patched CotabbyInference
source, and pinned dependency sources. Build instructions are in CONTRIBUTING.md and
releases/README.md. CoHamster is AGPLv3; dependency and data notices ship with the app and DMG.
Model weights are downloaded separately under their own terms. **SHA256SUMS.txt** covers both assets.

Validation: the latency changes passed 79 targeted and 757 regression tests, plus build-for-testing.
The release archive verifies the shared version and build number before packaging.
