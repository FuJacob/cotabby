#!/bin/bash
# Owns the fork's reproducible local packaging boundary: pinned native source + patch -> signed DMG.
# Credentials stay in Keychain. Fastlane owns publication after this boundary succeeds.
set -euo pipefail
cd "$(dirname "$0")/.."
# Read the same checked-in settings Xcode uses; release-only overrides hid stale local versions.
version=$(awk -F ' = ' '/^MARKETING_VERSION = / { print $2 }' Config/Version.xcconfig)
build_number=$(awk -F ' = ' '/^CURRENT_PROJECT_VERSION = / { print $2 }' Config/Version.xcconfig)
[[ -n "$version" && -n "$build_number" ]] || { echo 'Missing canonical version settings' >&2; exit 1; }
if [[ "${1:-$version}" != "$version" || "${2:-$build_number}" != "$build_number" ]]; then
    echo 'Update Config/Version.xcconfig first; release arguments must match local builds.' >&2
    exit 1
fi
# Each DMG must carry notes for its own version, never the first release's hardcoded file.
release_label="${COHAMSTER_RELEASE_LABEL:-$version}"
[[ "$release_label" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[1-9][0-9]*)?$ ]] || {
    echo 'Invalid release label' >&2; exit 1;
}
[[ "${release_label%%-*}" == "$version" ]] || { echo 'Release label must match MARKETING_VERSION' >&2; exit 1; }
release_notes="${COHAMSTER_RELEASE_NOTES:-releases/cohamster-${release_label}.md}"
[[ -f "$release_notes" ]] || { echo "Missing release notes: $release_notes" >&2; exit 1; }
identity="${COHAMSTER_SIGNING_IDENTITY:-Developer ID Application: Jorge Miguel Casler (8RN882MNR5)}"
[[ "$identity" == 'Developer ID Application:'* ]] || { echo 'Developer ID Application identity required' >&2; exit 1; }
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a stored Keychain notarization profile}"
notary_args=(--keychain-profile "$NOTARY_PROFILE")
if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then notary_args+=(--keychain "$NOTARY_KEYCHAIN"); fi
app_name='CoHamster'
release_dir="$PWD/build/cohamster-release"
native_dir="$release_dir/CotabbyInference"
xcodegen generate
scripts/prepare_cohamster_workspace.sh "$release_dir"
workspace="$release_dir/CoHamster.xcworkspace"
xcodebuild -resolvePackageDependencies -workspace "$workspace" -scheme "$app_name" \
    -onlyUsePackageVersionsFromResolvedFile -derivedDataPath build/DerivedData
xcodebuild archive \
    -workspace "$workspace" -scheme "$app_name" \
    -onlyUsePackageVersionsFromResolvedFile \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath build/DerivedData -archivePath "$release_dir/CoHamster.xcarchive" \
    DEVELOPMENT_TEAM=8RN882MNR5 CODE_SIGN_STYLE=Manual CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_IDENTITY="$identity" OTHER_CODE_SIGN_FLAGS=--timestamp \
    ARCHS=arm64
archive_app="$release_dir/CoHamster.xcarchive/Products/Applications/$app_name.app"
# Documents may be managed by iCloud, which restores FinderInfo immediately after xattr removal.
# Sign and package a metadata-free copy in the system temporary directory outside that provider.
staging_root=$(mktemp -d "${TMPDIR:-/tmp/}cohamster.XXXXXX")
trap 'rm -rf "$staging_root"' EXIT
stage="$staging_root/image"
mkdir -p "$stage/Licenses"
app="$stage/$app_name.app"
ditto --norsrc --noextattr "$archive_app" "$app"
xattr -cr "$app"
cp LICENSE "$stage/Licenses/CoHamster-AGPL-3.0.txt"
cp THIRD_PARTY_LICENSES.md "$stage/Licenses/THIRD_PARTY_LICENSES.md"
cp -R Cotabby/Resources/ThirdPartyLicenses "$stage/Licenses/Dependencies"
cp -R Cotabby/Resources/SpellingDictionaries/Licenses "$stage/Licenses/SpellingDictionaries"
cp Cotabby/Resources/SpellingDictionaries/NOTICE.md "$stage/Licenses/SpellingDictionaries/NOTICE.md"
cp "$native_dir/LICENSE" "$stage/Licenses/CotabbyInference-MIT.txt"
cp "$release_notes" "$stage/Release Notes.md"
# Re-sign Sparkle's nested helpers inside-out. Xcode may leave them signed by the vendor.
for nested in \
    Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate \
    Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app \
    Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc \
    Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc \
    Contents/Frameworks/Sparkle.framework Contents/Frameworks/llama.framework; do
    if [[ -e "$app/$nested" ]]; then
        codesign --force --options runtime --timestamp --sign "$identity" "$app/$nested"
    fi
done
codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
python3 - "$app/Contents/Info.plist" "$version" "$build_number" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as f:
    info = plistlib.load(f)
assert info['CFBundleIdentifier'] == 'org.mchamster.cotabby'
assert info['CFBundleName'] == 'CoHamster'
assert info['CFBundleShortVersionString'] == sys.argv[2]
assert info['CFBundleVersion'] == sys.argv[3]
assert 'SUFeedURL' not in info and 'SUPublicEDKey' not in info
PY
ln -sfn /Applications "$stage/Applications"
dmg="$release_dir/CoHamster-$release_label-arm64.dmg"
hdiutil create -ov -volname "$app_name" -srcfolder "$stage" -format UDZO "$staging_root/release.dmg"
codesign --force --timestamp --sign "$identity" "$staging_root/release.dmg"
ditto --norsrc --noextattr "$staging_root/release.dmg" "$dmg"
codesign --verify --strict "$dmg"
echo "Signed DMG: $dmg"
xcrun notarytool submit "$dmg" "${notary_args[@]}" --wait --output-format json > "$release_dir/notarization.json"
# notarytool's process status alone does not establish that Apple's verdict was Accepted.
python3 - "$release_dir/notarization.json" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    result = json.load(stream)
if result.get('status') != 'Accepted':
    raise SystemExit(f"Notarization failed: {result.get('status')} (submission {result.get('id')})")
PY
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"

(cd "$release_dir" && shasum -a 256 "$(basename "$dmg")" > SHA256SUMS.txt)
