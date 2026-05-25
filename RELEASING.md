# Releasing Cotabby (Sparkle)

Short, practical guide to signing + releasing updates.

---

## Mental Model (keep this)

Two separate systems:

1. **Apple signing (codesign + notarization)**
   → lets macOS run your app

2. **Sparkle signing (Ed25519)**
   → lets your app trust updates

Do not mix them.

---

## Current Config

- Feed: https://updates.cotabby.app/appcast.xml
- Public key (`SUPublicEDKey`):
  `efJeZNfUISOs6npbxI2MLLe7sBB5tT/sVnTk9t/qBSY=`

Private key = secret. Never commit it.

---

## One-Time Setup

### Make Sparkle commands easy

```sh
mkdir -p ~/bin

ln -sf "$(find ~/Library/Developer/Xcode/DerivedData -name generate_keys -type f | head -n 1)" ~/bin/sparkle-generate-keys
ln -sf "$(find ~/Library/Developer/Xcode/DerivedData -name sign_update -type f | head -n 1)" ~/bin/sparkle-sign-update
ln -sf "$(find ~/Library/Developer/Xcode/DerivedData -name generate_appcast -type f | head -n 1)" ~/bin/sparkle-generate-appcast

echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

Check:
```sh
which sparkle-generate-keys
```

---

## Sparkle Key

### Generate (once)
```sh
sparkle-generate-keys
```

### Print public key
```sh
sparkle-generate-keys -p
```

Must match `SUPublicEDKey`.

### Backup private key
```sh
sparkle-generate-keys -x ~/secure/Cotabby-key.txt
```

### Import on another machine
```sh
sparkle-generate-keys -f ~/secure/Cotabby-key.txt
```

---

## Release Flow (every release)

### 1. Sign app (Apple)
```sh
codesign --force --deep --options runtime \
--sign "Developer ID Application: Jacob Fu (G946M8K23B)" \
./Cotabby.app
```

### 2. Notarize
```sh
ditto -c -k --keepParent ./Cotabby.app Cotabby.zip
xcrun notarytool submit Cotabby.zip --keychain-profile "AC_PASSWORD" --wait
xcrun stapler staple ./Cotabby.app
```

---

### 3. Create the styled DMG

The release pipeline now builds a styled installer DMG through:

```sh
python3 -m pip install "dmgbuild[badge_icons]==1.6.7"
python3 scripts/build_release_dmg.py \
  --app-path /path/to/Cotabby.app \
  --output-path /path/to/Cotabby.dmg \
  --background-path assets/release/dmg_background.png \
  --background-2x-path assets/release/dmg_background@2x.png \
  --volume-name Cotabby
```

What this does:
- packages `Cotabby.app` with an `Applications` shortcut
- applies the committed background art from `assets/release/dmg_background.png`
- locks the icon layout for the drag-to-Applications flow
- reuses the app bundle icon as a best-effort mounted-volume badge when available

---

### 4. Sign update (Sparkle)
```sh
sparkle-sign-update /path/to/Cotabby.dmg
```

---

### 5. Generate appcast
```sh
python3 scripts/generate_appcast.py \
  --release-version 1.0.0 \
  --build-number 100 \
  --archive /path/to/Cotabby.dmg \
  --output build/appcast.xml \
  --ed-key-file ~/secure/Cotabby-key.txt
```

On your Mac, `--ed-key-file` is optional if the key is already in Keychain.
In GitHub Actions, we pass the key file explicitly from the `SPARKLE_ED25519_PRIVATE_KEY` secret.

---

## GitHub Actions Release

Workflow:
`.github/workflows/release.yml`

Trigger:
- Push a tag like `v0.0.2-beta` or `v1.0.0`
- Or run manually with `workflow_dispatch` for validation

### Tag naming and pre-release behavior

Tags with a hyphen suffix (e.g., `v0.0.1-beta`, `v1.0.0-rc1`) are automatically
marked as **Pre-release** on the GitHub Releases page. This means they won't
become the "Latest" release.

- **Beta/RC release**: `git tag v0.0.2-beta && git push origin v0.0.2-beta`
- **Stable release**: `git tag v1.0.0 && git push origin v1.0.0`

To promote a pre-release to Latest without re-running the pipeline:
```sh
gh release edit v0.0.1-beta --prerelease=false --latest
```

To re-release the same tag on a newer commit (e.g., hotfix):
```sh
gh release delete v0.0.1-beta --yes            # delete the GitHub Release
git push origin :refs/tags/v0.0.1-beta          # delete remote tag
git tag -f v0.0.1-beta                          # re-tag at current HEAD
git push origin v0.0.1-beta                     # push triggers pipeline
```

Required repo secrets:
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`
- `DEVELOPER_ID_APPLICATION_CERT`
- `DEVELOPER_ID_CERT_PASSWORD`
- `SPARKLE_ED25519_PRIVATE_KEY`

What CI does:
1. Imports the Developer ID certificate into a temporary keychain.
2. Installs the pinned `dmgbuild[badge_icons]` dependency.
3. Archives a Release build.
4. Packages a styled `Cotabby.dmg` with `scripts/build_release_dmg.py`.
5. Sends the DMG to Apple notarization.
6. Staples and validates the notarization ticket.
7. Verifies the Sparkle private key matches `SUPublicEDKey`.
8. Signs the final DMG with Sparkle.
9. Creates a GitHub Release with `Cotabby.dmg`.
10. Publishes `appcast.xml` to GitHub Pages last.

Pages output:
- `/appcast.xml`

The `/appcast.xml` path matches the current feed URL (`https://updates.cotabby.app/appcast.xml`).

---

## Sanity Checks

Check Apple signing:
```sh
spctl -a -t exec -vv ./Cotabby.app
```

Check Sparkle signature:
```sh
sparkle-sign-update /path/to/Cotabby.dmg
```

Signature must match appcast.

Check installer layout locally:
```sh
hdiutil attach /path/to/Cotabby.dmg
```

Verify the mounted image opens in icon view, shows the committed background
art, places `Cotabby.app` above the arrows, and places the `Applications` shortcut
inside the dashed drop target. The mounted volume badge is best-effort; do not
fail a release if the window layout is correct but Finder falls back to the
default disk icon.

---

## Rules (important)

- Never lose Sparkle private key → breaks updates
- Never rotate key casually → old installs will reject updates
- Never commit private key
- Always sign AFTER final DMG is built (no changes after)
- Always publish appcast AFTER the GitHub Release asset exists

---

## Rollback

Sparkle follows the appcast, not the GitHub Releases page.

To rollback:
1. Find the previous successful release run.
2. Restore that run's `appcast.xml`.
3. Redeploy it to GitHub Pages.
4. Leave the bad GitHub Release alone unless there is a security reason to remove it.

---

## If something breaks

Common issues:
- Wrong Sparkle key → updates rejected
- DMG changed after signing → signature invalid
- Missing notarization → macOS blocks app

Fix those first.
