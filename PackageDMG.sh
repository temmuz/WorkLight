#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")" && pwd)"
build_root="${WORKLIGHT_BUILD_DIR:-$project_root/.build-local}"
version="$(plutil -extract CFBundleShortVersionString raw "$project_root/Info.plist")"
app_path="$project_root/dist/Worklight.app"
output_path="${1:-$project_root/dist/Worklight-$version.dmg}"
stage="$(mktemp -d "$build_root/dmg.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

"$project_root/Build.sh" "$app_path"
ditto "$app_path" "$stage/Worklight.app"
ln -s /Applications "$stage/Applications"
cp "$project_root/README.md" "$stage/README.md"
cp "$project_root/LICENSE" "$stage/LICENSE"
mkdir -p "$(dirname "$output_path")"
hdiutil create -volname "Worklight" -srcfolder "$stage" -ov -format UDZO "$output_path"
printf 'Packaged %s\n' "$output_path"
