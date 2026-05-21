#!/usr/bin/env bash
# Build a local test DMG from the Debug app bundle.
# Usage: bash scripts/build_test_dmg.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="/tmp/TabbyDerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Debug/tabby.app"
OUTPUT_PATH="/tmp/tabby-test.dmg"
BACKGROUND="$REPO_ROOT/assets/release/dmg_background.png"

# Ensure dmgbuild is available.
if ! python3 -c "import dmgbuild" 2>/dev/null; then
    echo "Installing dmgbuild..."
    python3 -m pip install --user "dmgbuild[badge_icons]>=1.6.0"
fi

# Build the app if the bundle is missing.
if [ ! -d "$APP_PATH" ]; then
    echo "tabby.app not found — building..."
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
    --volume-name "tabby"

# Eject any stale tabby volumes so the DMG mounts exactly as /Volumes/tabby.
while IFS= read -r vol; do
    hdiutil detach "$vol" -quiet 2>/dev/null && echo "Ejected $vol" || true
done < <(ls /Volumes/ 2>/dev/null | grep -i "^tabby" | sed 's|^|/Volumes/|')

echo "Opening $OUTPUT_PATH"
open "$OUTPUT_PATH"
