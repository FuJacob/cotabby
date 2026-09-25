#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CoHamster"
BUNDLE_ID="org.mchamster.cotabby"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# This script owns local build/launch orchestration. Debug shares the installed app's
# bundle ID and permissions, so a valid signature alone is insufficient: use the same
# certificate class and verify its designated requirement before stopping the working app.
INSTALLED_APP="/Applications/$APP_NAME.app"
SIGNING_ARGS=()
INSTALLED_REQUIREMENT=""
if [[ -d "$INSTALLED_APP" ]]; then
  SIGNING_DETAILS="$(codesign -d -r- --verbose=2 "$INSTALLED_APP" 2>&1)"
  SIGNING_IDENTITY="$(sed -n 's/^Authority=//p' <<< "$SIGNING_DETAILS" | head -n 1)"
  INSTALLED_REQUIREMENT="$(sed -n 's/^designated => //p' <<< "$SIGNING_DETAILS")"
  if [[ -z "$SIGNING_IDENTITY" || -z "$INSTALLED_REQUIREMENT" ]]; then
    echo "Cannot determine installed app signing identity; leaving it running." >&2
    exit 1
  fi
  SIGNING_ARGS=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$SIGNING_IDENTITY")
fi

"$ROOT_DIR/scripts/prepare_cohamster_workspace.sh"
xcodebuild \
  -workspace "$ROOT_DIR/build/cohamster-dependencies/CoHamster.xcworkspace" \
  -onlyUsePackageVersionsFromResolvedFile \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  "${SIGNING_ARGS[@]}" \
  build

codesign --verify --deep --strict "$APP_BUNDLE"
if [[ -n "$INSTALLED_REQUIREMENT" ]]; then
  codesign --verify -R "=$INSTALLED_REQUIREMENT" "$APP_BUNDLE"
fi
# Stop only after a compatible build exists; two input monitors must not run together.
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

open_app() {
  /usr/bin/open -n "$APP_BUNDLE" --args -cotabby-debug
}

wait_for_app() {
  local attempt
  for attempt in {1..20}; do
    if pgrep -x "$APP_NAME" >/dev/null; then
      return 0
    fi
    sleep 0.25
  done

  echo "$APP_NAME did not launch within 5 seconds" >&2
  return 1
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY" -cotabby-debug
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    wait_for_app
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
