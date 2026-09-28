#!/bin/bash
# Makes a release of MacBook Duo to hand out: a universal build in a disk image that opens on any Mac
# without a warning. That takes two things from Apple: a Developer ID Application certificate, which
# signs it, and notarization, which checks it. The app is notarized and its ticket stapled to it
# first, so it opens even offline once it's copied out; then the disk image around it.
#
#   ./package.sh                       makes build/MacBook Duo <version>.dmg, for testing on this Mac
#   NOTARY_PROFILE=duo ./package.sh    also notarizes and staples it, with credentials saved once by
#                                      xcrun notarytool store-credentials duo
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=0 ./build.sh
app="build/MacBook Duo.app"
version=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
dmg="build/MacBook Duo $version.dmg"

# The disk image is signed with whatever signed the app.
# (awk reads to the end: stopping early would cut codesign off, which pipefail counts as failing.)
identity=$(codesign -dvv "$app" 2>&1 | awk -F= '/^Authority=/ && !found { print $2; found = 1 }')
if [[ "$identity" != Developer\ ID* ]]; then
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        echo "error: notarizing needs a Developer ID Application certificate, and this is signed with" >&2
        echo "       \"${identity:-no certificate}\". Create one in Xcode › Settings › Accounts › Manage Certificates." >&2
        exit 1
    fi
    echo "note: signed with \"${identity:-no certificate}\", not a Developer ID certificate, so other Macs" >&2
    echo "      will refuse to open it; this image is only for testing on this Mac." >&2
fi

# Sends `$1` to Apple and waits, stopping with Apple's findings if it isn't accepted.
notarize() {
    local output id
    output=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
    echo "$output"
    if ! grep -q "status: Accepted" <<< "$output"; then
        id=$(awk '/^ *id:/ && !found { print $2; found = 1 }' <<< "$output")
        [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
        echo "error: Apple didn't accept $1" >&2
        exit 1
    fi
}

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    zip="build/MacBook Duo $version.zip"
    ditto -c -k --keepParent "$app" "$zip"
    notarize "$zip"
    rm -f "$zip"
    xcrun stapler staple "$app"
fi

staging=$(mktemp -d)
ditto "$app" "$staging/MacBook Duo.app"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -volname "MacBook Duo" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg" > /dev/null
rm -rf "$staging"
if [[ -n "$identity" ]]; then
    options=(--force --sign "$identity")
    [[ "$identity" == Developer\ ID* ]] && options+=(--timestamp)
    codesign "${options[@]}" "$dmg"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    notarize "$dmg"
    xcrun stapler staple "$dmg"
    # What Gatekeeper will say on someone else's Mac.
    spctl --assess --type execute --verbose "$app"
    spctl --assess --type open --context context:primary-signature --verbose "$dmg"
fi
echo "Made $dmg"
