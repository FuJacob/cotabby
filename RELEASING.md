# Releasing this Cotabby development fork

The maintainer uses the personal [Fastlane release process](fastlane/README.md); contributors
use the Xcode workflow in [CONTRIBUTING.md](CONTRIBUTING.md). The release lane builds the `Cotabby` scheme and packages
`Cotabby.app`, retaining the installed fork's bundle ID and signing identity. Updates remain manual
and open this fork's releases until an upstream migration has been tested.

The existing repository, release tag prefix, notes filenames, and CI credential names are kept
for compatibility with published fork releases. Historical artifacts are immutable. This cleanup
does not publish a release, configure an upstream updater, or declare the fork end-of-life.
