# Releasing Cotabby

The upstream Release workflow remains the distribution entry point: push a `v<version>` tag,
or dispatch it with `release_version` and `publish: false` to validate packaging without publishing.
It builds the production `Cotabby` scheme, signs with the configured upstream credentials,
notarizes and staples the DMG, then publishes the signed Sparkle appcast, GitHub release, Pages
site, and Homebrew cask update when publication is enabled.

The existing secret names, environments, appcast signing key, update feed, bundle identifier,
and tag-derived version / workflow-run build number remain unchanged. `Cotabby Dev` uses its
own identity and disables Sparkle in every build configuration.

The build stage first runs `scripts/prepare_cotabby_workspace.sh` to supply the pending
CotabbyInference APIs. This is the only native dependency preparation added to the release flow;
all functional app changes compile against the same package and patch as local builds and tests.
Once those APIs land upstream, the workspace override can be retired together with the patch.
Do not remove the patch before a compatible package revision is available.

See [CONTRIBUTING.md](CONTRIBUTING.md) for local builds and evaluations. Historical CoHamster
release notes describe past fork binaries and do not control Cotabby's release configuration.
