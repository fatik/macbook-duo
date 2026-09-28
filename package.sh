#!/bin/bash
# Makes a release of MacBook Duo to hand out: a universal build in a disk image, signed with a
# Developer ID certificate and, given notarization credentials, notarized by Apple and stapled, so
# it opens on any Mac without a warning.
#
#   ./package.sh                       makes build/MacBook Duo <version>.dmg
#   NOTARY_PROFILE=duo ./package.sh    also notarizes it, with credentials saved once by
#                                      xcrun notarytool store-credentials duo
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=0 ./build.sh
app="build/MacBook Duo.app"
version=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
dmg="build/MacBook Duo $version.dmg"

# The disk image is signed with whatever signed the app.
identity=$(codesign -dvv "$app" 2>&1 | awk -F= '/^Authority=/ { print $2; exit }')
if [[ "$identity" != Developer\ ID* ]]; then
    echo "note: signed with \"${identity:-no certificate}\", not a Developer ID certificate, so other Macs" >&2
    echo "      will refuse to open it; this image is only for testing on this Mac." >&2
fi

staging=$(mktemp -d)
ditto "$app" "$staging/MacBook Duo.app"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -volname "MacBook Duo" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg" > /dev/null
rm -rf "$staging"
if [[ -n "$identity" ]]; then
    codesign --force --sign "$identity" --timestamp "$dmg"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$dmg"
    spctl --assess --type open --context context:primary-signature --verbose "$dmg"
fi
echo "Made $dmg"
