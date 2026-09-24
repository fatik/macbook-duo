#!/bin/bash
# Builds the apps into ./build without needing an Xcode project, then installs copies in
# ~/Applications so they can be opened from Spotlight, Launchpad or the Dock.
set -euo pipefail
cd "$(dirname "$0")"

build_app() {
    local name=$1 bundle_id=$2
    shift 2
    local app="build/$name.app"

    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "Resources/$name.icns" "$app/Contents/Resources/AppIcon.icns"
    if [[ -n "${SCENES:-}" ]]; then
        cp -R "$SCENES" "$app/Contents/Resources/"
    fi
    swiftc -O -parse-as-library -target arm64-apple-macos14.0 "$@" -o "$app/Contents/MacOS/$name"
    sed -e "s/__NAME__/$name/g" -e "s/__ID__/$bundle_id/g" Info.plist > "$app/Contents/Info.plist"
    if [[ -n "${CAMERA_USAGE:-}" ]]; then
        plutil -insert NSCameraUsageDescription -string "$CAMERA_USAGE" "$app/Contents/Info.plist"
    fi
    # Metal shaders go into the library SwiftUI's ShaderLibrary loads by default.
    if [[ -n "${METAL_SOURCES:-}" ]]; then
        local airs=()
        for shader in $METAL_SOURCES; do
            local air="build/$(basename "$shader" .metal).air"
            xcrun metal -c "$shader" -o "$air" -mmacosx-version-min=14.0
            airs+=("$air")
        done
        xcrun metallib "${airs[@]}" -o "$app/Contents/Resources/default.metallib"
        rm -f "${airs[@]}"
    fi
    codesign --force --sign - "$app"
    echo "Built $app"

    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/$name.app"
    ditto "$app" "$HOME/Applications/$name.app"
    echo "Installed ~/Applications/$name.app"
}

build_app Lid local.lid.app Sources/Shared/*.swift Sources/Lid/*.swift
CAMERA_USAGE="Straight uses the camera to find where your eyes are, so the card can be drawn for your point of view." \
METAL_SOURCES="Sources/Straight/*.metal" \
SCENES="Resources/Scene" \
    build_app Straight local.lid.straight Sources/Shared/*.swift Sources/Straight/*.swift
