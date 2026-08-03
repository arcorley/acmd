#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
info_plist="$project_dir/Scripts/ACMD-Info.plist"
version=$(plutil -extract CFBundleShortVersionString raw "$info_plist")
architecture=$(uname -m)

"$script_dir/build-app.sh" release

app_path="$project_dir/.build/ACMD.app"
dist_dir="$project_dir/dist"
dmg_path="$dist_dir/ACMD-${version}-macOS-${architecture}.dmg"
staging_path=$(mktemp -d "$project_dir/.build/ACMD-dmg.XXXXXX")
trap 'rm -rf "$staging_path"' EXIT

mkdir -p "$dist_dir"
ditto "$app_path" "$staging_path/ACMD.app"
ln -s /Applications "$staging_path/Applications"

hdiutil create \
    -volname "ACMD ${version}" \
    -srcfolder "$staging_path" \
    -ov \
    -format UDZO \
    "$dmg_path"

hdiutil verify "$dmg_path"
shasum -a 256 "$dmg_path"
echo "$dmg_path"
