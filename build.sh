#!/bin/bash
# Builds the apps into ./build without needing an Xcode project.
set -euo pipefail
cd "$(dirname "$0")"

build_app() {
    local name=$1 bundle_id=$2
    shift 2
    local app="build/$name.app"

    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS"
    swiftc -O -parse-as-library -target arm64-apple-macos14.0 "$@" -o "$app/Contents/MacOS/$name"
    sed -e "s/__NAME__/$name/g" -e "s/__ID__/$bundle_id/g" Info.plist > "$app/Contents/Info.plist"
    if [[ -n "${CAMERA_USAGE:-}" ]]; then
        plutil -insert NSCameraUsageDescription -string "$CAMERA_USAGE" "$app/Contents/Info.plist"
    fi
    codesign --force --sign - "$app"
    echo "Built $app"
}

build_app Lid local.lid.app Sources/Shared/*.swift Sources/Lid/*.swift
CAMERA_USAGE="Straight uses the camera to find where your eyes are, so the card can be drawn for your point of view." \
    build_app Straight local.lid.straight Sources/Shared/*.swift Sources/Straight/*.swift
