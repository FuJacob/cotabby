# Tabby → Cotabby Rename: Manual Update Checklist

Everything you need to do **outside** the codebase (or that can't be verified
by `xcodebuild`). Check each box as you complete it.

---

## 1. DNS & Domain

- [ ] **Register/configure `cotabby.app` domain** — the landing page URL
      (`https://cotabby.app`) and feedback URL (`https://www.cotabby.app/feedback`)
      must resolve.
- [ ] **Create CNAME record** `updates.cotabby.app` → your GitHub Pages site
      (e.g. `fujacob.github.io`). The release workflow writes a CNAME file with
      this value and publishes the Sparkle appcast there.
- [ ] **Enable GitHub Pages custom domain** in repo Settings → Pages, set to
      `updates.cotabby.app`, and enforce HTTPS.

---

## 2. Apple Developer Portal

- [ ] **Register new bundle identifier** `com.jacobfu.cotabby` in the Apple
      Developer portal (Certificates, Identifiers & Profiles → Identifiers).
- [ ] **Create/update provisioning profile** if you use one for Developer ID
      distribution.
- [ ] **Verify Developer ID Application certificate** is still valid and matches
      the `DEVELOPER_ID_APPLICATION_CERT` GitHub secret (the cert itself doesn't
      change, but the signed app will now have the new bundle ID).

> **User impact:** Existing users on `com.jacobfu.tabby` will see Cotabby as a
> **new app** — separate Accessibility trust, separate preferences, separate
> Login Items entry. Consider shipping a migration note or blog post.

---

## 3. GitHub Repository

- [ ] **Rename the repo** from `FuJacob/Tabby` to `FuJacob/Cotabby`. GitHub
      auto-redirects old URLs, but update bookmarks and CI badge URLs.
- [ ] **Update repo description and topics** in Settings to say "Cotabby".
- [ ] **Update GitHub Pages source** if it changed during the rename.

---

## 4. GitHub Secrets (Settings → Secrets and variables → Actions)

These secrets are already stored — **no values change**, but verify they're
present and that the workflow can still read them after a repo rename:

| Secret | Used for |
|--------|----------|
| `DEVELOPER_ID_APPLICATION_CERT` | Base64-encoded Developer ID cert for codesigning |
| `DEVELOPER_ID_CERT_PASSWORD` | Password for the cert import |
| `APPLE_ID` | Apple ID for notarization (`xcrun notarytool`) |
| `APPLE_TEAM_ID` | Team ID for codesigning and notarization |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for notarytool |
| `SPARKLE_ED25519_PRIVATE_KEY` | Sparkle signing key for appcast deltas |

> The keychain profile names (`cotabby-release.keychain-db`,
> `cotabby-notarytool-profile`) are **runtime artifacts** created inside the
> workflow — they don't map to stored secrets. They're already updated in
> `release.yml`.

---

## 5. Sparkle Update Feed

- [ ] **Verify DNS** for `updates.cotabby.app` resolves (see section 1).
- [ ] **Back up the Sparkle private key** — the workflow reads it from
      `SPARKLE_ED25519_PRIVATE_KEY`. Your local backup should be at
      `~/secure/Cotabby-key.txt` (referenced in `RELEASING.md`).
- [ ] **Do NOT rotate the Sparkle key pair** unless absolutely necessary —
      existing installs validate updates against the public key
      (`SUPublicEDKey` in `CotabbyInfo.plist`). Rotating breaks OTA updates for
      every prior install.

---

## 6. Buy Me a Coffee

- [ ] **Create the account** `cotabbyapp` on Buy Me a Coffee (or verify it
      exists). The handle is referenced in `.github/FUNDING.yml`.

---

## 7. Landing Page & Feedback Form

- [ ] **Deploy a page** at `https://cotabby.app` (linked from `README.md`).
- [ ] **Deploy a feedback form** at `https://www.cotabby.app/feedback`
      (linked from the in-app "Send Feedback" menu item in `CotabbyApp.swift`).

---

## 8. Remaining In-Code Renames (PR follow-ups)

These are code changes that weren't included in the rename PR but should be
done as follow-ups:

### 8a. `TabbyLogger` → `CotabbyLogger`

`TabbyLogger` is still used across **25 source files (86 occurrences)**.
The logger subsystem strings also still say `com.tabby.*`:

| File | What to change |
|------|---------------|
| `Cotabby/Support/CotabbyDebugOptions.swift:38` | Rename `enum TabbyLogger` → `CotabbyLogger` |
| `CotabbyDebugOptions.swift:50–56` | Change labels: `com.tabby.app` → `com.cotabby.app`, etc. (7 loggers) |
| `CotabbyDebugOptions.swift:70` | Change subsystem: `com.tabby.app` → `com.cotabby.app` |
| `CotabbyDebugOptions.swift:37` | Update comment: process "tabby" → "cotabby" |
| `CotabbyDebugOptions.swift:68` | Update comment: "all Tabby output" → "all Cotabby output" |
| 24 other Swift files | Replace all `TabbyLogger.` → `CotabbyLogger.` references |

> **Impact:** Changing `com.tabby.*` subsystem strings means any developer
> Console.app filters for `com.tabby.*` will stop matching. This is cosmetic
> but worth noting in release notes.

### 8b. AppDelegate log message

| File | Line | Current | Should be |
|------|------|---------|-----------|
| `Cotabby/App/Core/AppDelegate.swift` | 117 | `"Tabby \(version) (build \(build))..."` | `"Cotabby \(version)..."` |

### 8c. LlamaMiddleware / TabbyInference package

The local package at `../LlamaMiddleware` still exports a product called
`TabbyInference`. This is a separate repo/package — rename independently:

- [ ] Rename the product in `LlamaMiddleware/Package.swift` from
      `TabbyInference` to `CotabbyInference` (or similar).
- [ ] Update `import TabbyInference` in `LlamaRuntimeCore.swift` and
      `TabbyInference` references in `Cotabby.xcodeproj/project.pbxproj`.

### 8d. Old `tabby.xcodeproj` skeleton

The directory `tabby.xcodeproj/` still exists with leftover user data
(`xcuserdata/`). It's not tracked by git but clutters the working tree:

```bash
rm -rf tabby.xcodeproj
```

### 8e. Archived marketing text

`posts.txt` and `launch.txt` in the repo root contain old "Tabby" marketing
copy. Decide whether to update or delete them.

---

## 9. Post-Merge Verification

After merging and completing the above:

- [ ] **Tag a test release** and confirm the full release workflow succeeds
      (codesign, notarize, DMG, appcast publish).
- [ ] **Verify appcast** is reachable at
      `https://updates.cotabby.app/appcast.xml`.
- [ ] **Install from DMG** on a clean machine and confirm:
  - App name shows "Cotabby" in menu bar, About, and Activity Monitor.
  - Accessibility permission prompt references "Cotabby".
  - "Check for Updates" points to the new feed URL.
  - "Send Feedback" opens `https://www.cotabby.app/feedback`.
- [ ] **Verify Login Items** — if users had "Tabby" in Login Items, they'll
      need to re-add "Cotabby" manually.
- [ ] **Communicate to users** about the rename — existing installs will not
      auto-update to the new bundle ID. Users need to download the new app.

---

## Quick Reference: What Changed Where

| Item | Old value | New value | Where |
|------|-----------|-----------|-------|
| Bundle ID | `com.jacobfu.tabby` | `com.jacobfu.cotabby` | `project.pbxproj` |
| App name | Tabby | Cotabby | Everywhere |
| Xcode project | `tabby.xcodeproj` | `Cotabby.xcodeproj` | Repo root |
| Scheme | `tabby` | `Cotabby` | `.xcscheme` |
| Source dir | `tabby/` | `Cotabby/` | Repo root |
| Test dir | `tabbyTests/` | `CotabbyTests/` | Repo root |
| Info.plist | `TabbyInfo.plist` | `CotabbyInfo.plist` | Repo root |
| Update feed | `updates.tabbyapp.dev` | `updates.cotabby.app` | `CotabbyInfo.plist`, `release.yml` |
| Landing page | `tabbyapp.dev` | `cotabby.app` | `README.md`, `CotabbyApp.swift` |
| BMAC handle | `tabbyapp` | `cotabbyapp` | `FUNDING.yml` |
| DMG volume | "Tabby" | "Cotabby" | `release.yml` |
| Debug options | `TabbyDebugOptions` | `CotabbyDebugOptions` | Source |
| Launch arg | `-tabby-debug` | `-cotabby-debug` | Source |
