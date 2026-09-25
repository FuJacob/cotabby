#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
CONFIGURATION="${2:-Debug}"
case "$MODE" in run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;; *)
  echo "usage: $0 [run|debug|logs|telemetry|verify] [Debug|Release]" >&2; exit 2;;
esac
case "$CONFIGURATION" in Debug|Release) ;; *) echo 'Use Debug or Release' >&2; exit 2;; esac
APP_NAME="CoHamster"
BUNDLE_ID="org.mchamster.cotabby"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
# Keep the runnable copy outside both DerivedData and Documents/iCloud. A file
# provider can reattach FinderInfo after verification and invalidate nested code.
# Scope by checkout so worktrees do not overwrite one another's runnable product.
CHECKOUT_ID=$(printf '%s' "$ROOT_DIR" | shasum -a 256 | cut -c1-12)
RUN_DIR="$HOME/Library/Application Support/CoHamster/Development/$CHECKOUT_ID/$CONFIGURATION"
APP_BUNDLE="$RUN_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# This script owns local build/launch orchestration. Debug shares the installed app's
# bundle ID and permissions, so a valid signature alone is insufficient: use the same
# certificate class and verify its designated requirement before stopping the working app.
INSTALLED_APP="/Applications/$APP_NAME.app"
SIGNING_IDENTITY="${COHAMSTER_SIGNING_IDENTITY:-Apple Development}"
INSTALLED_REQUIREMENT=""
if [[ ! -d "$INSTALLED_APP" && -d "$APP_BUNDLE" ]]; then
  INSTALLED_APP="$APP_BUNDLE"
fi
if [[ -d "$INSTALLED_APP" ]]; then
  SIGNING_DETAILS="$(codesign -d -r- --verbose=2 "$INSTALLED_APP" 2>&1)"
  SIGNING_IDENTITY="$(sed -n 's/^Authority=//p' <<< "$SIGNING_DETAILS" | head -n 1)"
  INSTALLED_REQUIREMENT="$(sed -n 's/^designated => //p' <<< "$SIGNING_DETAILS")"
  if [[ -z "$SIGNING_IDENTITY" || -z "$INSTALLED_REQUIREMENT" ]]; then
    echo "Cannot determine installed app signing identity; leaving it running." >&2
    exit 1
  fi
fi

"$ROOT_DIR/scripts/prepare_cohamster_workspace.sh"
# Materialize binary package artifacts before building from a cleared DerivedData tree.
xcodebuild -resolvePackageDependencies \
  -workspace "$ROOT_DIR/build/cohamster-dependencies/CoHamster.xcworkspace" \
  -scheme "$APP_NAME" -onlyUsePackageVersionsFromResolvedFile -derivedDataPath "$DERIVED_DATA"
xcodebuild \
  -workspace "$ROOT_DIR/build/cohamster-dependencies/CoHamster.xcworkspace" \
  -onlyUsePackageVersionsFromResolvedFile \
  -scheme "$APP_NAME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

local_signing_args=(--identity "$SIGNING_IDENTITY")
if [[ "$CONFIGURATION" == Debug ]]; then local_signing_args+=(--debug); fi
python3 "$ROOT_DIR/scripts/sign_local_app.py" "$BUILT_APP" "${local_signing_args[@]}"

mkdir -p "$RUN_DIR"
staging_root=$(mktemp -d "$RUN_DIR/staging.XXXXXX")
trap 'rm -rf "$staging_root"' EXIT
candidate="$staging_root/$APP_NAME.app"
ditto --norsrc --noextattr "$BUILT_APP" "$candidate"
codesign --verify --deep --strict "$candidate"
if [[ -n "$INSTALLED_REQUIREMENT" ]]; then
  codesign --verify -R "=$INSTALLED_REQUIREMENT" "$candidate"
fi
# Stop only after a compatible build exists; two input monitors must not run together.
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
# Give the old process time to release its Accessibility observers and input tap.
for attempt in {1..40}; do
  pgrep -x "$APP_NAME" >/dev/null || break
  sleep 0.25
done
if pgrep -x "$APP_NAME" >/dev/null; then
  echo 'Existing CoHamster did not stop; leaving its app bundle intact.' >&2
  exit 1
fi
if [[ -d "$APP_BUNDLE" ]]; then mv "$APP_BUNDLE" "$staging_root/previous.app"; fi
mv "$candidate" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE" --args -cotabby-debug
}

wait_for_app() {
  local attempt
  for attempt in {1..20}; do
    if pgrep -x "$APP_NAME" >/dev/null; then
      echo "CoHamster is running from: $APP_BUNDLE"
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
    wait_for_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY" -cotabby-debug
    ;;
  --logs|logs)
    open_app
    wait_for_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    wait_for_app
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
