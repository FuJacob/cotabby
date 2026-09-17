# McHamster release process

`Config/McHamsterInfo.plist` owns distribution metadata for the separate `Cotabby McHamster` target in `project.yml`. Its name and bundle identifier isolate model storage, preferences, credentials, and permission grants. It deliberately has no upstream Sparkle feed or public key. The existing application environment still owns the updater; the McHamster compile condition disables automatic updating and routes manual checks to the fork's release page. Menu and About headers read the built bundle name.

`scripts/release_mchamster.sh` owns local release packaging. It checks out CotabbyInference at `7574a21`, applies the checked-in patch, verifies that source on subsequent runs, creates a separate ignored release workspace, loads the committed `Config/McHamster.Package.resolved` dependency pins, archives the McHamster target, signs nested code inside-out, verifies identity, and creates an Apple Silicon DMG. The patch records the native changes required by the fork without modifying upstream's repository or depending on uncommitted local files.

Prerequisites: Xcode, Developer ID certificate/private key for team `8RN882MNR5`, and a Keychain notarization profile. No private keys or passwords belong in this repository. Set up the profile interactively:

```sh
xcrun notarytool store-credentials McHamster --apple-id YOUR_APPLE_ID --team-id 8RN882MNR5
```

Build and notarize:

```sh
NOTARY_PROFILE=McHamster scripts/release_mchamster.sh 0.6.2-mchamster.1 2026091701
```

Without `NOTARY_PROFILE`, the script produces only a signed candidate. Do not publish it until Apple accepts notarization, stapling validates, and Gatekeeper accepts the DMG. Keep the output and checksum from `build/mchamster-release/`; remove `build/DerivedData` after validation.

Publish only to `mc-hamster/cotabby`, using a `mchamster-v*` tag and the reviewed notes in this directory. The inherited upstream release and Pages workflows are restricted to `FuJacob/cotabby`; this local process never dispatches updates to upstream's Homebrew tap or Pages domain. Use GitHub's prerelease flag while this fork remains experimental.

The original `Cotabby` and `Cotabby Dev` targets retain their upstream identities. Distribute only the `Cotabby McHamster` target from this fork. Quit upstream Cotabby before running the fork's autocomplete.
