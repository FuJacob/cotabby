#!/usr/bin/env bash
# kickstart.sh - reset this Mac to a first-install state and hand you a fresh Cotabby DMG.
#
# Use it to walk the real new-user path end to end: DMG window -> drag to Applications -> first
# launch -> onboarding -> permission prompts. It covers both app identities (release
# com.jacobfu.tabby and dev com.jacobfu.tabby.dev) because they share TCC, UserDefaults, and
# Application Support conventions, and a stale copy of either can make results misleading.
#
# What it does, in order:
#   1. Stops running Cotabby / Cotabby Dev processes (exact process names, never a broad pkill).
#   2. Resets every TCC permission (Accessibility, Input Monitoring, Screen Recording, ...), before
#      removal and again against the new build.
#   3. Ejects mounted Cotabby volumes, then removes installed/built app bundles for both identities.
#   4. Deletes preferences (via `defaults`, so cfprefsd's cache is cleared too), caches, logs,
#      saved state, and web/HTTP storage. Application Support is cleared except downloaded models,
#      unless --wipe-models is passed.
#   5. Builds a Release DMG the same way .github/workflows/release.yml does (archive, Developer ID
#      signing with hardened runtime, nested re-sign, styled DMG, signed DMG) and opens it.
#
# Why Developer ID signing matters here: TCC remembers a grant by bundle id *and* code signature.
# An ad-hoc signature changes on every build, so permissions would never "stick" and persistence
# testing would be meaningless. Developer ID matches what users run. The one gap versus a real
# release is notarization, which needs CI credentials; a locally built DMG is not quarantined, so
# Gatekeeper still lets it open.
#
# Usage: bash scripts/kickstart.sh [options]
#   --wipe-models   Also delete downloaded models (multi-GB re-download on next onboarding).
#   --clean-only    Reset this Mac but skip building the DMG.
#   --no-open       Build the DMG but do not open it.
#   --adhoc         Ad-hoc sign instead of Developer ID (permissions will not persist across builds).
#   -y, --yes       Skip the confirmation prompt.
#   -h, --help      Show this help.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Each pair is "<bundle id>|<product name>". The product name doubles as the executable name and
# the Application Support / Logs folder name.
APPS=("com.jacobfu.tabby|Cotabby" "com.jacobfu.tabby.dev|Cotabby Dev")
# Folders under Application Support that hold downloaded models. Everything else there is state.
MODEL_DIRS=("LlamaRuntime" "MlxRuntime")
OUT_DIR="$REPO_ROOT/build/kickstart"
DMG_PATH="$OUT_DIR/Cotabby.dmg"
VENV_DIR="/tmp/Cotabby-dmg-venv"
# Local builds are stamped far above any CI run number so Sparkle never offers to "update" the
# test build back to the latest public release mid-walkthrough.
BUILD_NUMBER=999999

wipe_models=false
clean_only=false
open_dmg=true
adhoc=false
assume_yes=false

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --wipe-models) wipe_models=true ;;
        --clean-only) clean_only=true ;;
        --no-open) open_dmg=false ;;
        --adhoc) adhoc=true ;;
        -y|--yes) assume_yes=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
note() { printf '    %s\n' "$1"; }

bundle_id_of() { /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$1/Contents/Info.plist" 2>/dev/null || true; }
is_cotabby_id() { [[ "$1" == "com.jacobfu.tabby" || "$1" == "com.jacobfu.tabby.dev" ]]; }

# Pick the signing identity up front so a missing certificate fails before anything is deleted.
signing_identity=""
if ! $clean_only; then
    if $adhoc; then
        signing_identity="-"
    elif security find-identity -v -p codesigning | grep -q '"Developer ID Application'; then
        signing_identity="Developer ID Application"
        team_id="$(security find-identity -v -p codesigning | sed -n 's/.*"Developer ID Application: .*(\([A-Z0-9]\{10\}\))".*/\1/p' | head -1)"
    else
        echo "No 'Developer ID Application' certificate found in your keychain." >&2
        echo "Re-run with --adhoc to continue (permissions will not persist across rebuilds)." >&2
        exit 1
    fi
fi

cat <<EOF
Cotabby kickstart will reset this Mac to a first-install state for BOTH app identities:
  - quit Cotabby and Cotabby Dev, remove installed/built app bundles
  - delete preferences, caches, logs, and saved state (onboarding will run again)
  - reset all privacy permissions (Accessibility, Input Monitoring, Screen Recording)
  - $($wipe_models && echo "DELETE downloaded models" || echo "keep downloaded models ($(IFS=,; echo "${MODEL_DIRS[*]}"))")
EOF
$clean_only || echo "  - build and $($open_dmg && echo "open" || echo "leave") a signed DMG at ${DMG_PATH#"$REPO_ROOT"/}"
if ! $assume_yes; then
    read -r -p "Continue? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

step "Stopping Cotabby processes"
for entry in "${APPS[@]}"; do
    name="${entry#*|}"
    # -x matches the process name exactly, so Xcode builds, test runners, and anything else with
    # "Cotabby" in its arguments are left alone.
    pkill -x "$name" 2>/dev/null && note "stopped $name" || true
done
# Sparkle's helpers run under their own names but carry the bundle id in their arguments.
pkill -f "com.jacobfu.tabby/org.sparkle-project" 2>/dev/null || true
pkill -f "Autoupdate com.jacobfu.tabby" 2>/dev/null || true
sleep 1

step "Ejecting mounted Cotabby volumes"
for vol in /Volumes/Cotabby*; do
    [[ -d "$vol" ]] && hdiutil detach "$vol" -quiet 2>/dev/null && note "ejected $vol"
done

step "Resetting privacy permissions"
# This must run before app bundles are removed: tccutil only resolves a bundle id that Launch
# Services still knows about. The post-build pass below catches grants whose app was deleted by an
# earlier run.
for entry in "${APPS[@]}"; do
    id="${entry%%|*}"
    if tccutil reset All "$id" >/dev/null 2>&1; then
        note "reset $id"
    else
        note "skipped $id (no registered app; retried after the build for the release id)"
    fi
done

step "Removing app bundles"
removed=0
candidates=()
for dir in /Applications "$HOME/Applications" "$HOME/Desktop" "$HOME/Downloads"; do
    [[ -d "$dir" ]] && while IFS= read -r app; do candidates+=("$app"); done \
        < <(find "$dir" -maxdepth 2 -name 'Cotabby*.app' -type d 2>/dev/null)
done
# Built products share the bundle id; if one is launched later it can take over the TCC entry.
for dd in "$REPO_ROOT/build" "$HOME/Library/Developer/Xcode/DerivedData"; do
    [[ -d "$dd" ]] && while IFS= read -r app; do candidates+=("$app"); done \
        < <(find "$dd" -path '*/Build/Products/*' -name 'Cotabby*.app' -type d -prune 2>/dev/null)
done
for app in ${candidates[@]+"${candidates[@]}"}; do
    if is_cotabby_id "$(bundle_id_of "$app")"; then
        rm -rf "$app" && note "removed $app" && removed=$((removed + 1))
    fi
done
[[ $removed -eq 0 ]] && note "none found"

step "Deleting preferences, caches, logs, and saved state"
for entry in "${APPS[@]}"; do
    id="${entry%%|*}"; name="${entry#*|}"
    # `defaults delete` goes through cfprefsd; deleting only the plist file would leave the cached
    # domain alive and the app would read its old settings back.
    defaults delete "$id" 2>/dev/null && note "cleared preferences for $id" || true
    rm -f "$HOME/Library/Preferences/$id.plist"
    rm -rf "$HOME/Library/Caches/$id" \
        "$HOME/Library/HTTPStorages/$id" "$HOME/Library/HTTPStorages/$id.binarycookies" \
        "$HOME/Library/Saved Application State/$id.savedState" \
        "$HOME/Library/WebKit/$id" \
        "$HOME/Library/Logs/$name"

    support="$HOME/Library/Application Support/$name"
    [[ -d "$support" ]] || continue
    if $wipe_models; then
        rm -rf "$support" && note "deleted $support (including models)"
    else
        # Remove everything except model folders so onboarding sees a fresh app with models on disk.
        while IFS= read -r item; do
            keep=false
            for model_dir in "${MODEL_DIRS[@]}"; do [[ "$(basename "$item")" == "$model_dir" ]] && keep=true; done
            $keep || rm -rf "$item"
        done < <(find "$support" -mindepth 1 -maxdepth 1)
        note "cleared $support (kept models)"
    fi
done

if $clean_only; then
    step "Done (clean only)"
    exit 0
fi

step "Building signed Release DMG"
mkdir -p "$OUT_DIR"
archive="$OUT_DIR/Cotabby.xcarchive"
rm -rf "$archive" "$DMG_PATH"
"$REPO_ROOT/scripts/prepare_cotabby_workspace.sh"

marketing_version="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
marketing_version="${marketing_version:-0.0.0}-kickstart"
sign_settings=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$signing_identity")
[[ "$signing_identity" == "-" ]] || sign_settings+=(DEVELOPMENT_TEAM="$team_id" OTHER_CODE_SIGN_FLAGS="--timestamp")

xcodebuild archive \
    -workspace "$REPO_ROOT/build/cotabby-dependencies/Cotabby.xcworkspace" \
    -scheme Cotabby \
    -configuration Release \
    -archivePath "$archive" \
    -derivedDataPath "$OUT_DIR/DerivedData" \
    -destination 'generic/platform=macOS' \
    "${sign_settings[@]}" \
    MARKETING_VERSION="$marketing_version" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    -quiet
app_path="$archive/Products/Applications/Cotabby.app"
note "archived Cotabby $marketing_version ($BUILD_NUMBER)"

# Mirror the release workflow: Xcode can leave Sparkle's helpers ad-hoc signed, so re-sign nested
# code inside-out with the same identity and hardened runtime.
sign_flags=(--force --sign "$signing_identity")
[[ "$signing_identity" == "-" ]] || sign_flags+=(--options runtime --timestamp)
frameworks="$app_path/Contents/Frameworks"
for code in \
    "$frameworks/Sparkle.framework/Versions/B/Autoupdate" \
    "$frameworks/Sparkle.framework/Versions/B/Updater.app" \
    "$frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" \
    "$frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" \
    "$frameworks/Sparkle.framework" \
    "$frameworks/llama.framework" \
    "$app_path"; do
    [[ -e "$code" ]] && codesign "${sign_flags[@]}" "$code"
done
codesign --verify --deep --strict "$app_path"
note "signed with: $([[ "$signing_identity" == "-" ]] && echo "ad-hoc" || echo "$signing_identity ($team_id)")"

# dmgbuild lives in an isolated venv because Homebrew Python is externally managed (PEP 668).
[[ -x "$VENV_DIR/bin/python3" ]] || python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/python3" -c "import dmgbuild" 2>/dev/null \
    || "$VENV_DIR/bin/python3" -m pip install --quiet "dmgbuild[badge_icons]>=1.6.0"
"$VENV_DIR/bin/python3" "$REPO_ROOT/scripts/build_release_dmg.py" \
    --app-path "$app_path" \
    --output-path "$DMG_PATH" \
    --background-path "$REPO_ROOT/assets/release/dmg_background.png" \
    --background-2x-path "$REPO_ROOT/assets/release/dmg_background@2x.png" \
    --volume-name "Cotabby"
if [[ "$signing_identity" != "-" ]]; then
    codesign --force --sign "$signing_identity" --options runtime --timestamp "$DMG_PATH"
    codesign --verify --strict "$DMG_PATH"
fi
note "DMG ready: $DMG_PATH"

# A grant can outlive its app: if an earlier run deleted every copy, the reset above had nothing to
# resolve against. The new build has the same bundle id and (with Developer ID) the same signing
# requirement, so it would silently inherit that grant. Register the archived app just long enough
# to reset the release id against it, then unregister so Launch Services never opens this copy.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$lsregister" -f "$app_path"
tccutil reset All com.jacobfu.tabby >/dev/null && note "reset com.jacobfu.tabby against the new build"
"$lsregister" -u "$app_path"

if $open_dmg; then
    open "$DMG_PATH"
    step "Walk through it"
    note "1. Drag Cotabby into Applications in the DMG window, then open it from Applications."
    note "2. Go through onboarding and grant the permissions it asks for."
    note "3. Quit and reopen Cotabby to confirm the permissions stuck."
    note "Logs: /usr/bin/log stream --predicate 'subsystem == \"com.cotabby.app\"' --level info"
fi
