# Releasing tabby (Sparkle)

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

- Feed: https://updates.tabbyapp.dev/appcast.xml
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
sparkle-generate-keys -x ~/secure/tabby-key.txt
```

### Import on another machine
```sh
sparkle-generate-keys -f ~/secure/tabby-key.txt
```

---

## Release Flow (every release)

### 1. Sign app (Apple)
```sh
codesign --force --deep --options runtime \
--sign "Developer ID Application: Jacob Fu (G946M8K23B)" \
./tabby.app
```

### 2. Notarize
```sh
ditto -c -k --keepParent ./tabby.app tabby.zip
xcrun notarytool submit tabby.zip --keychain-profile "AC_PASSWORD" --wait
xcrun stapler staple ./tabby.app
```

---

### 3. Create the styled DMG

The release pipeline now builds a styled installer DMG through:

```sh
python3 -m pip install "dmgbuild[badge_icons]==1.6.7"
python3 scripts/build_release_dmg.py \
  --app-path /path/to/tabby.app \
  --output-path /path/to/tabby.dmg \
  --background-path assets/release/dmg_background.png \
  --volume-name tabby
```

What this does:
- packages `tabby.app` with an `Applications` shortcut
- applies the committed background art from `assets/release/dmg_background.png`
- locks the icon layout for the drag-to-Applications flow
- reuses the app bundle icon as a best-effort mounted-volume badge when available

---

### 4. Sign update (Sparkle)
```sh
sparkle-sign-update /path/to/tabby.dmg
```

---

### 5. Generate appcast
```sh
python3 scripts/generate_appcast.py \
  --release-version 1.0.0 \
  --build-number 100 \
  --archive /path/to/tabby.dmg \
  --output build/appcast.xml \
  --ed-key-file ~/secure/tabby-key.txt
```

On your Mac, `--ed-key-file` is optional if the key is already in Keychain.
In GitHub Actions, we pass the key file explicitly from the `SPARKLE_ED25519_PRIVATE_KEY` secret.

---

## GitHub Actions Release

Workflow:
`.github/workflows/release.yml`

Trigger:
- Push a tag like `v1.0.0`
- Or run manually with `workflow_dispatch` for validation

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
4. Packages a styled `tabby.dmg` with `scripts/build_release_dmg.py`.
5. Sends the DMG to Apple notarization.
6. Staples and validates the notarization ticket.
7. Verifies the Sparkle private key matches `SUPublicEDKey`.
8. Signs the final DMG with Sparkle.
9. Creates a GitHub Release with `tabby.dmg`.
10. Publishes `appcast.xml` to GitHub Pages last.

Pages output:
- `/appcast.xml`

The `/appcast.xml` path matches the current feed URL (`https://updates.tabbyapp.dev/appcast.xml`).

---

## Sanity Checks

Check Apple signing:
```sh
spctl -a -t exec -vv ./tabby.app
```

Check Sparkle signature:
```sh
sparkle-sign-update /path/to/tabby.dmg
```

Signature must match appcast.

Check installer layout locally:
```sh
hdiutil attach /path/to/tabby.dmg
```

Verify the mounted image opens in icon view, shows the committed background
art, places `tabby.app` above the arrows, and places the `Applications` shortcut
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
