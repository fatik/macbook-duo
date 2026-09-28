#!/bin/bash
# Builds the apps into ./build without needing an Xcode project, then installs copies in
# ~/Applications so they can be opened from Spotlight, Launchpad or the Dock.
#
#   ./build.sh               builds and installs MacBook Duo and Lid
#   INSTALL=0 ./build.sh     builds without installing
#   ARCHS=arm64 ./build.sh   builds for Apple silicon only, which is quicker
set -euo pipefail
cd "$(dirname "$0")"

VERSION=1.0
# Every commit is a new build number, so macOS never mistakes one build for another.
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
ARCHS=${ARCHS:-arm64 x86_64}
INSTALL=${INSTALL:-1}

# Signed with a Developer ID certificate if there is one, for sharing the app; otherwise with a
# development certificate, so permissions like Screen Recording outlast a rebuild; otherwise ad hoc.
identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
identity=$(awk -F'"' '/Developer ID Application/ { print $2; exit }' <<< "$identities")
[[ -n "$identity" ]] || identity=$(awk -F'"' '/Apple Development/ { print $2; exit }' <<< "$identities")

build_app() {
    local name=$1 executable=$2 bundle_id=$3 icon=$4
    shift 4
    local app="build/$name.app"

    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "Resources/$icon.icns" "$app/Contents/Resources/AppIcon.icns"
    if [[ -n "${SCENES:-}" ]]; then
        cp -R "$SCENES" "$app/Contents/Resources/"
    fi

    # One slice per architecture, joined into a universal binary.
    local slices=()
    for arch in $ARCHS; do
        swiftc -O -parse-as-library -target "$arch-apple-macos14.0" "$@" -o "build/$executable-$arch"
        slices+=("build/$executable-$arch")
    done
    lipo -create "${slices[@]}" -output "$app/Contents/MacOS/$executable"
    rm -f "${slices[@]}"

    sed -e "s/__NAME__/$name/g" -e "s/__EXECUTABLE__/$executable/g" -e "s/__ID__/$bundle_id/g" \
        -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" Info.plist > "$app/Contents/Info.plist"
    if [[ -n "${CAMERA_USAGE:-}" ]]; then
        plutil -insert NSCameraUsageDescription -string "$CAMERA_USAGE" "$app/Contents/Info.plist"
    fi

    # Metal shaders go into the default library the app loads.
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

    # The hardened runtime, with only what the app needs: the camera, for calibrating by camera.
    local entitlements="Resources/$executable.entitlements"
    local options=(--force --options runtime)
    [[ -f "$entitlements" ]] && options+=(--entitlements "$entitlements")
    [[ "$identity" == Developer\ ID* ]] && options+=(--timestamp)
    codesign "${options[@]}" --sign "${identity:--}" "$app"
    echo "Built $app"

    if [[ "$INSTALL" == 1 ]]; then
        mkdir -p "$HOME/Applications"
        rm -rf "$HOME/Applications/$name.app"
        ditto "$app" "$HOME/Applications/$name.app"
        echo "Installed ~/Applications/$name.app"
    fi
}

build_app Lid Lid local.lid.app Lid Sources/Shared/*.swift Sources/Lid/*.swift
CAMERA_USAGE="Used only while calibrating, to find your eyes. Nothing is recorded." \
METAL_SOURCES="Sources/MacBookDuo/*.metal" \
SCENES="Resources/Scene" \
    build_app "MacBook Duo" MacBookDuo com.fatikowais.macbookduo MacBookDuo Sources/Shared/*.swift Sources/MacBookDuo/*.swift
