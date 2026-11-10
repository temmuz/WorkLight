#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")" && pwd)"
build_root="${WORKLIGHT_BUILD_DIR:-$project_root/.build-local}"
app_path="${1:-$project_root/dist/Worklight.app}"
mkdir -p "$build_root" "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
export CLANG_MODULE_CACHE_PATH="$build_root/module-cache"
export SWIFT_MODULECACHE_PATH="$build_root/module-cache"
read -r -a architectures <<< "${WORKLIGHT_ARCHS:-arm64 x86_64}"
binaries=()

for architecture in "${architectures[@]}"; do
    triple="${architecture}-apple-macosx13.0"
    swift_options=(--package-path "$project_root" --disable-sandbox -debug-info-format none --triple "$triple" --scratch-path "$build_root/swift-build-$architecture" --cache-path "$build_root/swift-cache" --config-path "$build_root/swift-config" --security-path "$build_root/swift-security")
    swift build "${swift_options[@]}" -c release --product Worklight
    bin_path="$(swift build "${swift_options[@]}" -c release --show-bin-path)"
    binaries+=("$bin_path/Worklight")
done

if [[ ${#binaries[@]} -eq 1 ]]; then
    cp "${binaries[0]}" "$app_path/Contents/MacOS/Worklight"
else
    lipo -create "${binaries[@]}" -output "$app_path/Contents/MacOS/Worklight"
fi

cp "$project_root/Info.plist" "$app_path/Contents/Info.plist"
swift -module-cache-path "$build_root/module-cache" "$project_root/MakeIcon.swift" "$build_root" "$app_path/Contents/Resources/Worklight.icns"
codesign --force --deep --sign - --identifier app.worklight.timer "$app_path"
codesign --verify --deep --strict "$app_path"
printf 'Built %s\n' "$app_path"
