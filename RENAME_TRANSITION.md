# Tabby → Cotabby Rename Transition

This document records what changed, what intentionally stayed the same, and
what would break if touched in the future. Keep it as a reference for any
follow-up work on the rename.

---

## What Was Renamed (Visual / Cosmetic)

These changes shipped in the rename PR and are safe — they don't affect
existing installs, preferences, permissions, or update delivery.

| Item | Old | New |
|------|-----|-----|
| Source directory | `tabby/` | `Cotabby/` |
| Test directory | `tabbyTests/` | `CotabbyTests/` |
| Xcode project | `tabby.xcodeproj` | `Cotabby.xcodeproj` |
| Xcode scheme | `tabby` | `Cotabby` |
| Info.plist | `TabbyInfo.plist` | `CotabbyInfo.plist` |
| App struct | `TabbyApp` | `CotabbyApp` |
| Environment | `TabbyAppEnvironment` | `CotabbyAppEnvironment` |
| Debug options | `TabbyDebugOptions` | `CotabbyDebugOptions` |
| Launch argument | `-tabby-debug` | `-cotabby-debug` |
| Test fixtures | `TabbyTestFixtures` | `CotabbyTestFixtures` |
| DMG volume name | `Tabby` | `Cotabby` |
| DMG filename | `tabby.dmg` | `Cotabby.dmg` |
| CI workflow names | References to "Tabby" | References to "Cotabby" |
| README, docs, comments | "Tabby" | "Cotabby" |
| Accessibility description | "Tabby needs..." | "Cotabby needs..." |
| UI strings, log messages | "Tabby" | "Cotabby" |
| Keychain profile names | `tabby-release.keychain-db` | `cotabby-release.keychain-db` |
| Notarytool profile | `tabby-notarytool-profile` | `cotabby-notarytool-profile` |

Keychain and notarytool profile names are runtime artifacts created inside
the CI workflow — they don't map to stored secrets or external state.

---

## What Was Intentionally NOT Renamed

These identifiers are functional — changing them would break existing user
installs. They must stay as-is unless a migration path is implemented.

### Bundle Identifier: `com.jacobfu.tabby`

**What depends on it:**
- macOS Accessibility trust (TCC database keyed by bundle ID)
- Input Monitoring permission grant
- Screen Recording permission grant
- Login Items / `SMAppService` registration
- `UserDefaults` storage domain (implicitly `com.jacobfu.tabby`)
- macOS Gatekeeper / quarantine state
- Any MDM or enterprise allowlist entries users may have configured

**What would break:**
Changing the bundle ID makes macOS treat the app as a completely new
application. Every user would need to:
- Re-grant Accessibility permission (re-drag in System Settings)
- Re-grant Input Monitoring permission
- Re-grant Screen Recording permission
- Re-enable Login Items
- Lose all saved preferences (engine choice, keybindings, disabled apps, etc.)

### UserDefaults Keys: `tabby*` Prefix

All 14 preference keys use the `tabby` prefix:

| Key | Purpose |
|-----|---------|
| `tabbyGloballyEnabled` | Master on/off toggle |
| `tabbyDisabledAppRules` | Per-app blocklist |
| `tabbyShowCaretIndicator` | Caret indicator visibility |
| `tabbySelectedIndicatorMode` | Indicator style |
| `tabbyCustomSuggestionTextColorHex` | Ghost text color |
| `tabbyClipboardContextEnabled` | Clipboard context toggle |
| `tabbyUserName` | User's name for prompts |
| `tabbyDebounceMilliseconds` | Input debounce timing |
| `tabbyFocusPollIntervalMilliseconds` | Focus poll interval |
| `tabbyAcceptanceKeyCode` | Partial accept key |
| `tabbyAcceptanceKeyLabel` | Partial accept key label |
| `tabbyFullAcceptanceKeyCode` | Full accept key |
| `tabbyFullAcceptanceKeyLabel` | Full accept key label |
| `selectedSuggestionEngine` | Engine choice (no prefix) |
| `selectedSuggestionWordCountPreset` | Word count preset (no prefix) |

**What would break:** Renaming these keys silently resets every user's
preferences to defaults on next launch. The two keys without the `tabby`
prefix (`selectedSuggestionEngine`, `selectedSuggestionWordCountPreset`)
were never renamed and should also stay as-is.

### Sparkle Feed URL: `https://updates.tabbyapp.dev/appcast.xml`

The `SUFeedURL` in `CotabbyInfo.plist` points to the old domain. Existing
installs have this URL baked into their running binary and poll it for
updates.

**Current setup:**
- `updates.tabbyapp.dev` has a Cloudflare 301 redirect →
  `updates.cotabby.app` (same path preserved)
- GitHub Pages serves the appcast at `updates.cotabby.app`
- Sparkle follows the redirect transparently

**What would break:** Removing the `updates.tabbyapp.dev` domain or its
redirect before all users have updated to a version with the new feed URL
would silently break OTA updates. Users would never see new versions.

**Future migration path (when ready):**
1. ✅ Confirm `updates.tabbyapp.dev` → `updates.cotabby.app` redirect is live
   (done).
2. ✅ Ship a release with `SUFeedURL` changed to
   `https://updates.cotabby.app/appcast.xml` in `CotabbyInfo.plist` (done — the
   `SUFeedURL` now points at `updates.cotabby.app`; takes effect on the next
   tagged release).
3. ⏳ Keep the `tabbyapp.dev` redirect alive for at least 6 months to catch
   users who don't update immediately. **Do not retire it yet.**
4. After sufficient time, retire `updates.tabbyapp.dev`.

### Sparkle Signing Key

The Ed25519 key pair must never change unless you're willing to break all
OTA updates for every existing install:

- **Public key** (`SUPublicEDKey` in `CotabbyInfo.plist`):
  `efJeZNfUISOs6npbxI2MLLe7sBB5tT/sVnTk9t/qBSY=`
- **Private key**: stored in the `SPARKLE_ED25519_PRIVATE_KEY` GitHub
  secret and backed up locally at `~/secure/Cotabby-key.txt` (per
  `RELEASING.md`).

Rotating this key means every previously-shipped build will reject all
future updates as untrusted.

### Logger Subsystem: `com.tabby.*` → `com.cotabby.*` ✅ DONE

The `TabbyLogger` enum and its `com.tabby.app`, `com.tabby.runtime`, etc.
subsystem strings have been renamed to `CotabbyLogger` and `com.cotabby.*`.
These appear in Console.app as filterable subsystem identifiers.

This had no user-facing impact (the only cost was invalidating any developer's
Console.app saved filters keyed to the old subsystem), so it was completed as
part of the rename cleanup. `FileLogHandler.category(from:)` derives the
category from the third dotted component, so it keeps working unchanged.

### PAGES_CUSTOM_DOMAIN: `updates.tabbyapp.dev`

The release workflow's `PAGES_CUSTOM_DOMAIN` environment variable is set to
`updates.tabbyapp.dev`. This controls the CNAME file written to the GitHub
Pages deployment.

**Current state:** GitHub Pages is actually deployed under
`updates.cotabby.app` (set via the republish-pages workflow). The release
workflow still writes `updates.tabbyapp.dev` — this will be overwritten on
the next release unless updated.

**✅ DONE:** `PAGES_CUSTOM_DOMAIN` in `release.yml` (and the
`republish-pages.yml` default) now point at `updates.cotabby.app`, so the
release workflow deploys Pages under the correct domain and no longer reverts
it. This is safe because the `tabbyapp.dev` redirect handles old installs.

---

## Follow-Up Candidates

These are low-priority items renamed without breaking anything for users.

### `TabbyLogger` → `CotabbyLogger` ✅ DONE

The logger factory enum has been renamed from `TabbyLogger` to `CotabbyLogger`
across all source and test files. Purely cosmetic — no runtime or persistence
impact.

### `AppDelegate.swift` Log Message ✅ DONE

The launch log line now reads `"Cotabby \(version) (build \(build))..."`.

### LlamaMiddleware / `TabbyInference` Package ✅ DONE

The inference dependency was replaced with `CotabbyInference` (see the
"Rename project to Cotabby and replace LlamaSwift with CotabbyInference"
change). No remaining `TabbyInference` references exist in the app target.

No user impact — this is a build-time dependency name only.

### Archived Marketing Text ✅ DONE

`posts.txt` and `launch.txt` are no longer present in the repo root.

### Old `tabby.xcodeproj` Skeleton ✅ DONE

No `tabby.xcodeproj/` directory remains in the working tree.

---

## External Services Checklist

| Service | Account / Identifier | Status |
|---------|---------------------|--------|
| GitHub repo | `FuJacob/tabby` | Not yet renamed to `FuJacob/Cotabby` |
| GitHub Pages | `updates.cotabby.app` | Live, serving appcast |
| DNS redirect | `updates.tabbyapp.dev` → `updates.cotabby.app` | Live (Cloudflare 301) |
| Buy Me a Coffee | `cotabbyapp` | Verify account exists |
| Landing page | `cotabby.app` | Verify deployed |
| Feedback form | `www.cotabby.app/feedback` | Verify deployed |
| Apple Developer | Bundle ID `com.jacobfu.tabby` | Registered (do NOT change) |
| Apple notarization | Team ID `C4BVFMK9V2` | No change needed |
| Sparkle key pair | Ed25519, stored in GitHub Secrets | No change needed |

---

## GitHub Secrets (No Changes Needed)

These secrets are stored in the repo's Actions settings. None need to be
renamed or rotated for the Cotabby rename:

| Secret | Purpose |
|--------|---------|
| `DEVELOPER_ID_APPLICATION_CERT` | Base64-encoded Developer ID certificate |
| `DEVELOPER_ID_CERT_PASSWORD` | Certificate import password |
| `APPLE_ID` | Apple ID for notarization |
| `APPLE_TEAM_ID` | Developer Team ID |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for notarytool |
| `SPARKLE_ED25519_PRIVATE_KEY` | Sparkle appcast signing key |

---

## DNS Architecture

```
Existing installs:
  App polls → updates.tabbyapp.dev/appcast.xml
           → Cloudflare 301 redirect
           → updates.cotabby.app/appcast.xml
           → GitHub Pages serves appcast

New installs (after feed URL migration):
  App polls → updates.cotabby.app/appcast.xml
           → GitHub Pages serves appcast
```

Both paths serve the same appcast from the same GitHub Pages deployment.

---

## Decision Log

| Decision | Rationale |
|----------|-----------|
| Keep bundle ID as `com.jacobfu.tabby` | Changing it resets all macOS permissions and treats the app as a new install |
| Keep UserDefaults keys as `tabby*` | Changing them silently wipes user preferences |
| Keep feed URL as `tabbyapp.dev` in shipped binary | Existing installs have this URL baked in; redirect handles the transition |
| Redirect `tabbyapp.dev` via Cloudflare | Zero-downtime migration; Sparkle follows 301s transparently |
| Rename source dirs, types, and UI strings | Purely cosmetic; no runtime or persistence impact |
| Keep Sparkle key pair unchanged | Rotating breaks OTA updates for all existing installs |
