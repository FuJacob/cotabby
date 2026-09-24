# CoHamster 0.6.3

The first release under the **CoHamster** name, September 24, 2026.

- CoHamster branding across macOS, onboarding, menus, settings, and model labels.
- Original hamster artwork for the app, menu bar, and field indicator.
- Existing fork settings, credentials, and downloaded models remain compatible.
- Feedback and manual update checks point to this repository. Automatic updates are disabled.

## Install

Download **CoHamster-0.6.3-arm64.dmg**, open it, and drag **CoHamster.app** into Applications.
Quit Cotabby McHamster or any other copy before opening CoHamster. Requires an Apple Silicon Mac
running macOS 14 or later; Apple Intelligence requires macOS 26 and supported hardware.
The app is Developer ID signed and notarized by Apple. This is a prerelease.

## Source and license

CoHamster is distributed under AGPLv3. The matching source is attached as
**CoHamster-0.6.3-source.tar.gz**, including the patched CotabbyInference source and pinned
third-party dependency sources. Build instructions are in CONTRIBUTING.md and releases/README.md.
License notices ship inside the app and DMG. Model weights are downloaded separately under their
own terms. SHA256SUMS.txt contains checksums for the download and source archive.

Validation: production and development builds succeeded; 153 targeted app tests and 30 tooling
tests passed before release packaging.
