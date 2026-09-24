#!/bin/bash
# Owns the fork's reproducible local packaging boundary: pinned native source + patch -> signed DMG.
# Credentials stay in Keychain. Publication is separate so a failed notarization cannot ship a DMG.
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:-0.6.4}"
build_number="${2:-2026092402}"
# Each DMG must carry notes for its own version, never the first release's hardcoded file.
release_notes="releases/cohamster-${version}.md"
[[ -f "$release_notes" ]] || { echo "Missing release notes: $release_notes" >&2; exit 1; }
identity='Developer ID Application: Jorge Miguel Casler (8RN882MNR5)'
app_name='CoHamster'
release_dir="$PWD/build/cohamster-release"
native_dir="$release_dir/CotabbyInference"
scripts/prepare_cohamster_workspace.sh "$release_dir"
workspace="$release_dir/CoHamster.xcworkspace"
xcodebuild archive \
    -workspace "$workspace" -scheme "$app_name" \
    -onlyUsePackageVersionsFromResolvedFile \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath build/DerivedData -archivePath "$release_dir/CoHamster.xcarchive" \
    DEVELOPMENT_TEAM=8RN882MNR5 CODE_SIGN_STYLE=Manual CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_IDENTITY="$identity" OTHER_CODE_SIGN_FLAGS=--timestamp \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" \
    ARCHS=arm64
archive_app="$release_dir/CoHamster.xcarchive/Products/Applications/$app_name.app"
# Documents may be managed by iCloud, which restores FinderInfo immediately after xattr removal.
# Sign and package a metadata-free copy in the system temporary directory outside that provider.
staging_root=$(mktemp -d "${TMPDIR:-/tmp/}cohamster.XXXXXX")
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
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as f:
    info = plistlib.load(f)
assert info['CFBundleIdentifier'] == 'org.mchamster.cotabby'
assert info['CFBundleName'] == 'CoHamster'
assert 'SUFeedURL' not in info and 'SUPublicEDKey' not in info
PY
ln -sfn /Applications "$stage/Applications"
dmg="$release_dir/CoHamster-$version-arm64.dmg"
hdiutil create -ov -volname "$app_name" -srcfolder "$stage" -format UDZO "$staging_root/release.dmg"
codesign --force --timestamp --sign "$identity" "$staging_root/release.dmg"
ditto --norsrc --noextattr "$staging_root/release.dmg" "$dmg"
codesign --verify --strict "$dmg"
echo "Signed DMG: $dmg"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
else
    echo 'Not notarized yet. Set NOTARY_PROFILE to your stored Keychain profile before publication.'
fi

(cd "$release_dir" && shasum -a 256 "$(basename "$dmg")" > SHA256SUMS.txt)
