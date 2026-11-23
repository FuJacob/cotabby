# Releasing Cotabby

The upstream Release workflow remains the distribution entry point: push a `v<version>` tag,
or dispatch it with `release_version` and `publish: false` to validate packaging without publishing.
It builds the production `Cotabby` scheme, signs with the configured upstream credentials,
notarizes and staples the DMG, then publishes the signed Sparkle appcast, GitHub release, Pages
site, and Homebrew cask update when publication is enabled.

The existing secret names, environments, appcast signing key, update feed, bundle identifier,
and tag-derived version / workflow-run build number remain unchanged. `Cotabby Dev` uses its
own identity and disables Sparkle in every build configuration.

There is one update feed, and every install polls it with automatic updates on. Only `vX.Y.Z`
and `vX.Y.Z-beta` (the suffix every release so far has used) update the appcast and the Homebrew
cask. Any other pre-release suffix, such as `-rc.1`, `-beta.2` or `-alpha`, publishes a GitHub
prerelease only, for manual testing. The published appcast also carries a Sparkle signature over
the whole feed; installs do not require it until `SURequireSignedFeed` is set in
`CotabbyInfo.plist`.

The build stage first runs `scripts/prepare_cotabby_workspace.sh`, which checks out the
CotabbyInference revision pinned in `project.yml` and pins every other package from
`Config/Package.resolved`. Releases therefore compile against exactly the same packages as local
builds and CI tests. Cotabby carries no native patch: a needed CotabbyInference API lands upstream
first, then both pins move together.

See [CONTRIBUTING.md](CONTRIBUTING.md) for local builds and evaluations.
