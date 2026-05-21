#!/usr/bin/env bash
# Build a local test DMG from the Debug app bundle.
# Usage: bash scripts/build_test_dmg.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="/tmp/TabbyDerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Debug/tabby.app"
OUTPUT_PATH="/tmp/tabby-test.dmg"
BACKGROUND="$REPO_ROOT/assets/release/dmg_background.png"
BACKGROUND_2X="$REPO_ROOT/assets/release/dmg_background@2x.png"
VENV_DIR="/tmp/tabby-dmg-venv"
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
    echo "Tabby.app not found — building..."
    # CODE_SIGNING_ALLOWED=NO so local builds work without a dev cert.
    # The test DMG is for visual layout iteration only — never shipped.
    xcodebuild \
        -project "$REPO_ROOT/tabby.xcodeproj" \
        -scheme tabby \
        -configuration Debug \
        -derivedDataPath "$DERIVED_DATA" \
        CODE_SIGNING_ALLOWED=NO \
        build
fi

echo "Building DMG..."
"$VENV_PY" "$REPO_ROOT/scripts/build_release_dmg.py" \
    --app-path "$APP_PATH" \
    --output-path "$OUTPUT_PATH" \
    --background-path "$BACKGROUND" \
    --background-2x-path "$BACKGROUND_2X" \
    --volume-name "Tabby"

# Eject any stale Tabby volumes so the DMG mounts as /Volumes/Tabby.
# The DS_Store background path is absolute — if it mounts as /Volumes/Tabby 2/
# the background reference breaks and Finder shows a blank window.
while IFS= read -r vol; do
    hdiutil detach "$vol" -quiet 2>/dev/null && echo "Ejected $vol"
done < <(ls /Volumes/ 2>/dev/null | grep -i "^Tabby" | sed 's|^|/Volumes/|')

echo "Opening $OUTPUT_PATH"
open "$OUTPUT_PATH"
