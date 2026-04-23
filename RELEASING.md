# Releasing Tabby (Sparkle)

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

- Feed: https://tabbyapp.dev/tabby/appcast.xml
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
ditto -c -k --keepParent ./tabby.app Tabby.zip
xcrun notarytool submit Tabby.zip --keychain-profile "AC_PASSWORD" --wait
xcrun stapler staple ./tabby.app
```

---

### 3. Create DMG (your existing process)

---

### 4. Sign update (Sparkle)
```sh
sparkle-sign-update /path/to/Tabby.dmg
```

---

### 5. Generate appcast
```sh
python3 scripts/generate_appcast.py \
  --release-version 1.0.0 \
  --build-number 100 \
  --archive /path/to/Tabby.dmg \
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
2. Archives a Release build.
3. Packages `Tabby.dmg`.
4. Sends the DMG to Apple notarization.
5. Staples and validates the notarization ticket.
6. Verifies the Sparkle private key matches `SUPublicEDKey`.
7. Signs the final DMG with Sparkle.
8. Creates a GitHub Release with `Tabby.dmg`.
9. Publishes `appcast.xml` to GitHub Pages last.

Pages output:
- `/appcast.xml`
- `/tabby/appcast.xml`

The `/tabby/appcast.xml` path matches the current feed URL.

---

## Sanity Checks

Check Apple signing:
```sh
spctl -a -t exec -vv ./tabby.app
```

Check Sparkle signature:
```sh
sparkle-sign-update /path/to/Tabby.dmg
```

Signature must match appcast.

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
