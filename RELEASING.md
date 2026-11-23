# Releasing Cotabby

The upstream Release workflow remains the distribution entry point: push a `v<version>` tag,
or dispatch it with `release_version` and `publish: false` to validate packaging without publishing.
It builds the production `Cotabby` scheme, signs with the configured upstream credentials,
notarizes and staples the DMG, then publishes the signed Sparkle appcast, GitHub release, Pages
site, and Homebrew cask update when publication is enabled.

A release must come from a commit that is already on `main`: the workflow fails first if a tag
points anywhere else, and manual runs must be dispatched from `main`. The signing secrets live in
the `release` environment (required reviewers, deployment refs limited to `main` and `v*` tags),
so the build and notarize jobs each wait for approval; notarize also Sparkle-signs the appcast,
and publish holds no signing secret. The secret names, appcast signing key, update feed, bundle
identifier, and tag-derived version / workflow-run build number are unchanged. `Cotabby Dev` uses
its own identity and disables Sparkle in every build configuration.

The build stage first runs `scripts/prepare_cotabby_workspace.sh`, which checks out the
CotabbyInference revision pinned in `project.yml` and pins every other package from
`Config/Package.resolved`. Releases therefore compile against exactly the same packages as local
builds and CI tests. Cotabby carries no native patch: a needed CotabbyInference API lands upstream
first, then both pins move together.

See [CONTRIBUTING.md](CONTRIBUTING.md) for local builds and evaluations.
