#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
info_plist="$project_dir/Scripts/ACMD-Info.plist"
version=$(plutil -extract CFBundleShortVersionString raw "$info_plist")
architecture=$(uname -m)
notary_profile=${ACMD_NOTARY_PROFILE:-}
notary_timeout=${ACMD_NOTARY_TIMEOUT:-30m}
signing_identity=${ACMD_SIGNING_IDENTITY:-}
team_id=${ACMD_TEAM_ID:-AJ64G3AGXL}

if [[ -z "$signing_identity" ]]; then
    signing_identity=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -F "($team_id)" \
        | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' \
        | head -1 || true)
fi

if [[ -n "$notary_profile" && -z "$signing_identity" ]]; then
    echo "Notarization requires a Developer ID Application identity for team $team_id" >&2
    exit 1
fi

if [[ -n "$notary_profile" && "$signing_identity" != *"($team_id)"* ]]; then
    echo "Signing identity does not belong to the expected team $team_id" >&2
    exit 1
fi

ACMD_SIGNING_IDENTITY="$signing_identity" "$script_dir/build-app.sh" release

app_path="$project_dir/.build/ACMD.app"
dist_dir="$project_dir/dist"
dmg_name="ACMD-${version}-macOS-${architecture}.dmg"
final_dmg_path="$dist_dir/$dmg_name"
staging_path=$(mktemp -d "$project_dir/.build/ACMD-dmg.XXXXXX")
artifact_path=$(mktemp -d "$project_dir/.build/ACMD-artifact.XXXXXX")
dmg_path="$artifact_path/$dmg_name"
trap 'rm -rf "$staging_path" "$artifact_path"' EXIT

mkdir -p "$dist_dir"
ditto "$app_path" "$staging_path/ACMD.app"
ln -s /Applications "$staging_path/Applications"

hdiutil create \
    -volname "ACMD ${version}" \
    -srcfolder "$staging_path" \
    -ov \
    -format UDZO \
    "$dmg_path"

if [[ -n "$signing_identity" ]]; then
    codesign \
        --force \
        --timestamp \
        --sign "$signing_identity" \
        "$dmg_path"
    codesign --verify --strict --verbose=2 "$dmg_path"
fi

hdiutil verify "$dmg_path"

if [[ -n "$notary_profile" ]]; then
    xcrun notarytool submit "$dmg_path" \
        --keychain-profile "$notary_profile" \
        --wait \
        --timeout "$notary_timeout"
    xcrun stapler staple "$dmg_path"
    xcrun stapler validate "$dmg_path"
    spctl --assess \
        --type open \
        --context context:primary-signature \
        --verbose=4 \
        "$dmg_path"
    hdiutil verify "$dmg_path"
fi

mv "$dmg_path" "$final_dmg_path"
shasum -a 256 "$final_dmg_path"
echo "$final_dmg_path"
