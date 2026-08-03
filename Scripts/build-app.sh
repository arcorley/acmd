#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
configuration=${1:-release}
signing_identity=${ACMD_SIGNING_IDENTITY:-}
team_id=${ACMD_TEAM_ID:-AJ64G3AGXL}

if [[ -z "$signing_identity" ]]; then
    signing_identity=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -F "($team_id)" \
        | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' \
        | head -1 || true)
fi

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

if [[ -n "$signing_identity" ]]; then
    echo "Signing with $signing_identity"
    codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$signing_identity" \
        "$bundle_path"
else
    echo "No Developer ID identity found; using an ad-hoc signature"
    codesign --force --sign - "$bundle_path"
fi

codesign --verify --deep --strict --verbose=2 "$bundle_path"
echo "$bundle_path"
