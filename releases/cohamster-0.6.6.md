# CoHamster 0.6.6

Improved local GGUF partial-word predictions, September 25, 2026.

- Fixes token healing to reconsider the entire current word within a bounded replay budget, instead of only its last token.
- Prefers tokens that cover the typed prefix; shorter token pieces are used only when no eligible covering token exists. Single-line filtering happens before this choice.
- Adds a repeatable usability harness and regression coverage for all four supported local models.
- Local development launches match the installed app’s signing identity and verify compatibility before restarting, preventing the Apple Development / Developer ID permission mismatch observed during testing.

Across 767 partial-word checkpoints per model and context condition, no-screen accuracy improved from 53–59% to 77–81%; with screen context it improved from 65–70% to 83–88%. Next-word accuracy was unchanged. These are fixed-scenario measurements, not a guarantee of prediction quality; longer continuations can still hallucinate. See `benchmarks/model-usability/2026-09-25-token-healing/` for methodology and results.

Validation of the inference changes: 8,952 evaluation checkpoints with zero runtime errors, 145 Swift tests, 24 native lifecycle checks, 64 Python harness tests, and native C++ tests.

## Install

Download **CoHamster-0.6.6-arm64.dmg**, quit CoHamster, and drag **CoHamster.app** into Applications.
Requires Apple Silicon and macOS 14 or later; Apple Intelligence requires macOS 26 and supported hardware.
This is a Developer ID signed prerelease. Preferences and downloaded models remain compatible.

## Source and license

**CoHamster-0.6.6-source.tar.gz** includes matching application source, patched CotabbyInference source, and pinned dependency sources. Build instructions are in CONTRIBUTING.md and releases/README.md. CoHamster is AGPLv3; dependency and data notices ship with the app and DMG. Model weights are downloaded separately under their own terms. **SHA256SUMS.txt** covers both assets.
