# CoHamster 0.6.7-beta.1

- Matches ghost text more closely to the focused field’s font, size, and margins, with appearance controls for sizing.
- Recognizes writable Mail web composers as editable fields.
- Improves Mail text-marker selection and handles non-breaking spaces so typing and accepting suggestions preserve the remaining suggestion.
- Adds the Fastlane validation and distribution pipeline, including artifact checksums and build provenance.
- Includes updated regression coverage and recorded full usability benchmark results.

## Install

Download **CoHamster-0.6.7-beta.1-arm64.dmg**, quit CoHamster, and drag **CoHamster.app** into Applications.
Requires Apple Silicon and macOS 14 or later; Apple Intelligence requires macOS 26 and supported hardware.
This is a prerelease. Preferences and downloaded models remain compatible.

## Source and license

The source archive includes the matching application source, patched CotabbyInference source, and build instructions. Model weights are downloaded separately under their own terms. CoHamster is AGPLv3; dependency notices ship with the app and DMG. Release assets include debug symbols, build provenance, and **SHA256SUMS.txt**.
