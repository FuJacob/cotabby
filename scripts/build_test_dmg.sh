#!/usr/bin/env bash
# Build a local test DMG from the Debug app bundle.
# Usage: bash scripts/build_test_dmg.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="/tmp/TabbyDerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Debug/Tabby.app"
OUTPUT_PATH="/tmp/Tabby-test.dmg"
BACKGROUND="$REPO_ROOT/assets/release/dmg_background.png"

# Ensure dmgbuild is available.
if ! python3 -c "import dmgbuild" 2>/dev/null; then
    echo "Installing dmgbuild..."
    python3 -m pip install --user "dmgbuild[badge_icons]==1.6.7"
fi

# Build the app if the bundle is missing.
if [ ! -d "$APP_PATH" ]; then
    echo "Tabby.app not found — building..."
    xcodebuild \
        -project "$REPO_ROOT/tabby.xcodeproj" \
        -scheme tabby \
        -configuration Debug \
        -derivedDataPath "$DERIVED_DATA" \
        build
fi

echo "Building DMG..."
python3 "$REPO_ROOT/scripts/build_release_dmg.py" \
    --app-path "$APP_PATH" \
    --output-path "$OUTPUT_PATH" \
    --background-path "$BACKGROUND" \
    --volume-name "Tabby"

echo "Opening $OUTPUT_PATH"
open "$OUTPUT_PATH"
