#!/usr/bin/env bash
# Build a local test DMG from the Debug app bundle.
# Usage: bash scripts/build_test_dmg.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="/tmp/CotabbyDerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Debug/Cotabby.app"
OUTPUT_PATH="/tmp/Cotabby-test.dmg"
BACKGROUND="$REPO_ROOT/assets/release/dmg_background.png"
BACKGROUND_2X="$REPO_ROOT/assets/release/dmg_background@2x.png"
VENV_DIR="/tmp/Cotabby-dmg-venv"
VENV_PY="$VENV_DIR/bin/python3"

# Ensure dmgbuild is available in an isolated venv.
# Homebrew Python is PEP 668-managed, so `pip install --user` fails. A
# project-local venv sidesteps that and keeps system Python clean.
if [ ! -x "$VENV_PY" ]; then
    echo "Creating dmgbuild venv at $VENV_DIR..."
    python3 -m venv "$VENV_DIR"
fi
if ! "$VENV_PY" -c "import dmgbuild" 2>/dev/null; then
    echo "Installing dmgbuild into venv..."
    "$VENV_PY" -m pip install --quiet --upgrade pip
    "$VENV_PY" -m pip install --quiet "dmgbuild[badge_icons]>=1.6.0"
fi

# Build the app if the bundle is missing.
if [ ! -d "$APP_PATH" ]; then
    echo "Cotabby.app not found, building..."
    xcodebuild \
        -project "$REPO_ROOT/Cotabby.xcodeproj" \
        -scheme Cotabby \
        -configuration Debug \
        -derivedDataPath "$DERIVED_DATA" \
        build
fi

# Debug builds aren't notarized, so Gatekeeper flags the app as "damaged"
# when opened from a DMG. Strip quarantine and ad-hoc codesign so the test
# DMG is launchable without manual xattr gymnastics.
echo "Stripping quarantine and ad-hoc signing..."
xattr -cr "$APP_PATH"
codesign --force --deep --sign - "$APP_PATH"

# Eject any stale Cotabby volumes before building so the DMG mounts cleanly.
# The DS_Store background path is absolute: if it mounts as /Volumes/Cotabby 2/
# the background reference breaks and Finder shows a blank window.
while IFS= read -r vol; do
    hdiutil detach "$vol" -quiet 2>/dev/null && echo "Ejected $vol"
done < <(ls /Volumes/ 2>/dev/null | grep -i "^Cotabby" | sed 's|^|/Volumes/|')

echo "Building DMG..."
"$VENV_PY" "$REPO_ROOT/scripts/build_release_dmg.py" \
    --app-path "$APP_PATH" \
    --output-path "$OUTPUT_PATH" \
    --background-path "$BACKGROUND" \
    --background-2x-path "$BACKGROUND_2X" \
    --volume-name "Cotabby"

# Strip quarantine from the output DMG itself.
xattr -cr "$OUTPUT_PATH"

echo "Opening $OUTPUT_PATH"
open "$OUTPUT_PATH"
