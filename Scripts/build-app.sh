#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
configuration=${1:-release}

cd "$project_dir"
swift build --configuration "$configuration"
binary_dir=$(swift build --configuration "$configuration" --show-bin-path)

bundle_path="$project_dir/.build/ACMD.app"
staging_path=$(mktemp -d "$project_dir/.build/ACMD.app.staging.XXXXXX")
trap 'rm -rf "$staging_path"' EXIT

mkdir -p "$staging_path/Contents/MacOS" "$staging_path/Contents/Resources"
ditto "$binary_dir/ACMD" "$staging_path/Contents/MacOS/ACMD"
ditto "$project_dir/Scripts/ACMD-Info.plist" "$staging_path/Contents/Info.plist"
ditto "$project_dir/Resources/AppIcon.icns" "$staging_path/Contents/Resources/AppIcon.icns"
chmod 755 "$staging_path/Contents/MacOS/ACMD"

if [[ -d "$bundle_path" ]]; then
    rm -rf "$bundle_path"
fi
mv "$staging_path" "$bundle_path"
trap - EXIT

codesign --force --deep --sign - "$bundle_path"
echo "$bundle_path"
