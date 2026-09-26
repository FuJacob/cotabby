# Cotabby Fastlane pipeline

Fastlane is the maintainer entry point for local builds and GitHub distribution. `Fastfile`
defines six commands. `lib/release_pipeline.rb` owns validation, artifact provenance, and GitHub
publication; the shell scripts own macOS build/signing mechanics. No lane changes versions,
commits source files, creates certificates, or uploads app prompts/model data.

## Setup

Install Ruby **4.0.2** (see `.ruby-version`), Xcode, XcodeGen, SwiftLint, and GitHub CLI. Put the
managed Ruby ahead of `/usr/bin` in `PATH`; macOS's Ruby 2.6 cannot run this bundle. For Homebrew
Ruby, use `export PATH="$(brew --prefix ruby)/bin:$PATH"`. From the repository root:

```sh
bundle config set --local path build/bundle
bundle install
gh auth login
bundle exec fastlane mac doctor
```

`Gemfile.lock` pins Fastlane and its dependencies. CI uses the same lockfile and Ruby version.
The signed lanes default to your existing Developer ID Application certificate for team
`8RN882MNR5`; its private key must be in an unlocked Keychain. An explicitly selected replacement
identity can be supplied as `COHAMSTER_SIGNING_IDENTITY`. Development also checks compatibility
with the installed app's designated signing requirement, helping preserve macOS permissions.

Notarization uses the existing `McHamster` Keychain profile. To create it interactively:

```sh
xcrun notarytool store-credentials McHamster --apple-id YOUR_APPLE_ID --team-id 8RN882MNR5
```

Set `NOTARY_PROFILE` for another profile and `NOTARY_KEYCHAIN` when it lives in a specific keychain.
`doctor` checks tools, the signing identity, online notarization authentication, and GitHub write
access. Apple signing and GitHub authentication are separate credentials.

## Commands

| Command | Behavior |
| --- | --- |
| `bundle exec fastlane mac dev` | Signed Debug build, signature compatibility check, stop old process, stage and launch with diagnostic logging. |
| `bundle exec fastlane mac dev logs:true` | Same build and launch, then follow Console logs until interrupted. |
| `bundle exec fastlane mac dev configuration:Release` | Launch an optimized local build with diagnostic logging. |
| `bundle exec fastlane mac verify` | Strict SwiftLint, XcodeGen drift check, Ruby pipeline tests, all Python script tests, and signed app-hosted unit tests. |
| `bundle exec fastlane mac verify signed:false` | Credential-free validation for contributor/PR environments. Never used to produce a distributed app. |
| `bundle exec fastlane mac package` | Create a signed/notarized stable package locally; no GitHub writes. |
| `bundle exec fastlane mac package suffix:beta.1` | Create a signed/notarized beta package locally. |
| `bundle exec fastlane mac prerelease suffix:beta.1` | Validate, package, and publish a GitHub pre-release. Also accepts `alpha.N` and `rc.N`. |
| `bundle exec fastlane mac release` | Validate, package, and publish stable as Latest. |
| `bundle exec fastlane mac doctor` | Read-only environment and credential diagnosis. |

`verify` intentionally skips `FoundationModelDriftEvalTests`: those require the real Apple
Intelligence model and are not deterministic CI tests. Existing model evaluation commands remain
available separately. A failed unit-test launch/signature is a failure, not a successful verify.
XcodeGen regeneration may update the generated project; any diff against HEAD fails the drift
gate so it can be reviewed and committed explicitly.

Local dev/test builds compile without signing, then `scripts/sign_local_app.py` signs a clean
temporary copy with the selected Apple identity and stages it back. This avoids Finder metadata
breaking codesign in Documents/iCloud checkouts. The test host and test bundle share that identity;
only test hosts receive the library-validation entitlement required for XCTest injection. Release
DMGs use the separate distribution signer and never receive test entitlements.

Each build lane holds a checkout-local lock and deletes only `build/DerivedData` on exit, even
after failure. Local apps survive in
`~/Library/Application Support/Cotabby/Development/<checkout-id>/<configuration>/Cotabby.app`,
outside Documents/iCloud; the checkout ID is the first 12 characters of its path's SHA-256.
Logs and test results survive in `build/fastlane-logs/<timestamp>-<pid>/`. Direct shell-script invocations do not
take the Fastlane lock; don't run them concurrently with a lane in the same checkout.

## Version and publication rules

1. Update `Config/Version.xcconfig`: `MARKETING_VERSION` is numeric `major.minor.patch`;
   `CURRENT_PROJECT_VERSION` is an increasing positive integer. Keep beta/RC suffixes in the tag
   and release label, not the bundle's numeric version.
2. Write `releases/cohamster-<version>.md` for stable, or
   `releases/cohamster-<version>-beta.1.md` for that exact beta. Commit the version, notes, and code.
3. For publication, push the commit first. Both package and publishing lanes require a clean
   checkout, including untracked source files. Dev and verify allow work in progress.
4. Run the desired lane. Tags are `cohamster-v<version>` or
   `cohamster-v<version>-beta.1`. A beta and final may share the numeric version, but every published
   build must have a greater build number; versions cannot move backwards or repeat stable.

The pipeline reads version files from existing published tags. Legacy releases predating
`Version.xcconfig` receive a version-only comparison, reported in the log. GitHub API errors other
than a missing legacy file fail the lane. Existing tags/releases are never replaced automatically.

`package` performs archive/signature/notarization checks, but does not run the full verify suite.
The two publishing lanes always run verify first. The DMG contains release notes, license notices,
the app, and the Applications shortcut. Release assets include:

- Notarized and stapled Apple Silicon DMG.
- Matching source archive, including the exact patched CotabbyInference source and build instructions.
- Debug symbols, release notes, and `release.json` with version/build/commit/toolchain provenance.
- `SHA256SUMS.txt`, computed after notarization and stapling.

Artifacts are retained in `build/releases/<label>-<build>/`. A retry refuses an existing output
directory; move the failed candidate aside explicitly. Packaging uses the existing
`build/cotabby-release/` staging workspace and preserves its archive for diagnosis.

Publication reserves the tag at the exact built commit, creates a draft, uploads every asset,
and checks GitHub's asset names, sizes, and SHA-256 digests. Only then is the draft published.
Pre-releases never become Latest. Failed uploads leave a draft and tag for diagnosis; no retry
deletes or replaces them. After inspection, remove an unpublished failed draft/tag explicitly or
use a new version/suffix. Already published versions should receive a new release.

## GitHub Actions

The **Distribution** workflow is manually triggered. Select a branch in **Actions → Distribution
→ Run workflow**, choose `package`, `prerelease`, or `release`, and supply a suffix when appropriate.
The selected event commit is checked out exactly. Package is the default and uploads CI artifacts
without creating a GitHub release. Distribution jobs are serialized and never cancel one another.

Create the GitHub environment **`cohamster-release`**, then add these secrets there:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_P12_BASE64` | Base64 of an exported Developer ID Application certificate **and private key** (`.p12`). |
| `APPLE_CERTIFICATE_PASSWORD` | Password protecting that `.p12`. |
| `APPLE_ID` | Apple account used for notarization. |
| `APPLE_APP_SPECIFIC_PASSWORD` | Its app-specific notarization password. |

GitHub supplies `GITHUB_TOKEN` with repository contents write permission for publishing. The
workflow currently pins macOS 26, Xcode 26.6, Ruby 4.0.2, and action commits. Update those pins
deliberately. `scripts/ci_keychain.py` imports Apple credentials into a temporary runner keychain,
stores the notarization profile there, and restores the prior search list/deletes the keychain in
an `always()` cleanup step. Credentials are not included in uploaded artifacts.

The separate **Fastlane** PR workflow exercises the publication guards without credentials.
App builds and tests now run through Fastlane verify; focused Lint and XcodeGen checks remain. Creating this
configuration does not create the GitHub environment/secrets or publish anything.

Cotabby currently opens this fork's GitHub Releases for update checks. No automatic updater is
bundled. The repository, `cohamster-v` tags, historical notes, `COHAMSTER_*` environment variables,
and signing credentials remain compatible with earlier fork releases. These are operational
identifiers, separate from the Cotabby app name and artwork. Upstream migration and EOL are pending.
