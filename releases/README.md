# CoHamster release process

`project.yml` owns the application targets and `Config/CoHamsterInfo.plist` owns distribution
metadata. The release is named **CoHamster**. Its existing `org.mchamster.cotabby` bundle identifier
and `Cotabby McHamster` data directory are compatibility identifiers: they preserve preferences,
Keychain credentials, and downloaded models from earlier fork releases. Keep the same signing team
when upgrading. macOS may still request permission again after an application replacement.

`scripts/release_cohamster.sh` owns local packaging. Its shared
`scripts/prepare_cohamster_workspace.sh` helper checks out CotabbyInference at `7574a21`,
applies `patches/cotabbyinference-mchamster.patch`, verifies the native diff before reuse, creates an
ignored workspace, uses `Config/McHamster.Package.resolved`, and archives the CoHamster scheme.
The source package and patch retain their upstream names. Nested binaries are signed inside-out;
the script verifies app identity and creates an Apple Silicon DMG with license notices and release notes.

Prerequisites: Xcode, Developer ID certificate/private key for team `8RN882MNR5`, and a Keychain
notarization profile. Keep credentials out of this repository. Configure the profile interactively:

```sh
xcrun notarytool store-credentials McHamster --apple-id YOUR_APPLE_ID --team-id 8RN882MNR5
```

Set the next version and build number in `Config/Version.xcconfig`, which is shared by Debug and
Release. Write matching `releases/cohamster-<version>.md` notes before building. The packaging
script regenerates the Xcode project, reads these canonical values, and verifies the archived app
matches them. Optional version/build arguments must agree with the file. Then:

```sh
NOTARY_PROFILE=McHamster scripts/release_cohamster.sh
```

Without `NOTARY_PROFILE`, the script produces only a signed candidate. Publish after notarization,
stapling, and Gatekeeper verification pass. Outputs are in `build/cohamster-release/`.
Remove `build/DerivedData` after validation.

Publish to `mc-hamster/CoHamster` using a `cohamster-v<version>` tag and that version's release notes.
Provide the matching source and build instructions next to every binary download, including the
pinned CotabbyInference source and applied patch. Preserve AGPLv3 and all dependency/data notices;
model weights retain their own licenses and are not included in the app. No upstream release or
Pages workflows are active in this fork. Manual update checks open this repository's release page.

Do not run another copy of the autocomplete app alongside CoHamster. Historical `mchamster-*`
release notes describe earlier versions and retain their original names.
