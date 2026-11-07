#!/bin/bash
# release.sh — build, sign, notarise and package SeekZip v0.2.0 (M7).
#
#   DEVELOPER_TEAM_ID=<Team ID> [NOTARY_PROFILE=seekzip-notary] \
#       [VERSION=0.2.0] ./scripts/release.sh [--skip-notarize]
#
# Runs on a Mac with full Xcode (see docs/RELEASE.md for the
# one-time setup: Apple Developer account, Team ID, App Group,
# notarytool keychain profile). Steps:
#   1. scripts/package-engines.sh — stage 7zz/lsar/unar (+ SHA-256 check)
#   2. xcodebuild archive (Release, Developer ID)
#   3. xcodebuild -exportArchive -> build/SeekZip.app
#   4. hdiutil DMG + ditto ZIP for the Homebrew cask
#   5. notarytool submit --wait, then stapler staple (app + DMG)
#   6. spctl --assess (Gatekeeper) + codesign verification
#   7. prints the SHA-256 values the Homebrew formula/cask need
#
# --skip-notarize still signs and packages, but skips steps 5-6
# (useful for a first unsigned smoke build; the result will NOT pass
# Gatekeeper on another Mac — do not distribute it).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.2.0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-seekzip-notary}"
SKIP_NOTARIZE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-notarize) SKIP_NOTARIZE=1; shift ;;
        *) echo "usage: $0 [--skip-notarize]" >&2; exit 2 ;;
    esac
done

if [ "$(uname)" != "Darwin" ]; then
    echo "release.sh runs on a Mac with Xcode (this is $(uname))." >&2
    exit 1
fi
for tool in xcodebuild hdiutil ditto codesign spctl; do
    command -v "$tool" >/dev/null 2>&1 ||
        { echo "missing required tool: $tool" >&2; exit 1; }
done
if [ -z "${DEVELOPER_TEAM_ID:-}" ]; then
    echo "DEVELOPER_TEAM_ID is not set." >&2
    echo "  Find it at https://developer.apple.com/account (Membership" >&2
    echo "  details) and re-run: DEVELOPER_TEAM_ID=<id> $0" >&2
    exit 1
fi

BUILD="$ROOT/build"
ARCHIVE="$BUILD/SeekZip.xcarchive"
APP="$BUILD/SeekZip.app"
DMG="$BUILD/SeekZip-$VERSION.dmg"
ZIP="$BUILD/SeekZip-$VERSION.zip"

echo "== 1. Staging engines =="
"$ROOT/scripts/package-engines.sh"

echo "== 2. Archiving (Xcode, Release) =="
xcodebuild -project "$ROOT/SeekZip.xcodeproj" \
    -scheme SeekZip -configuration Release \
    -archivePath "$ARCHIVE" \
    DEVELOPMENT_TEAM="$DEVELOPER_TEAM_ID" \
    archive

echo "== 3. Exporting Developer ID app =="
EXPORT_OPTS="$BUILD/ExportOptions.plist"
sed "s/YOUR_TEAM_ID/$DEVELOPER_TEAM_ID/g" \
    "$ROOT/packaging/ExportOptions.plist" > "$EXPORT_OPTS"
rm -rf "$APP"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportPath "$BUILD" -exportOptionsPlist "$EXPORT_OPTS"

echo "== 4. Packaging DMG + ZIP =="
rm -f "$DMG" "$ZIP"
hdiutil create -volname "SeekZip $VERSION" -srcfolder "$APP" \
    -ov -format UDZO "$DMG"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ "$SKIP_NOTARIZE" -eq 1 ]; then
    echo "== 5-6. Skipped (--skip-notarize): NOT Gatekeeper-clean. =="
else
    command -v xcrun >/dev/null 2>&1 ||
        { echo "missing required tool: xcrun" >&2; exit 1; }
    echo "== 5. Notarizing (profile: $NOTARY_PROFILE) =="
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "== 6. Stapling + Gatekeeper check =="
    xcrun stapler staple "$APP"
    xcrun stapler staple "$DMG"
    spctl --assess --type execute --verbose "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
fi

echo ""
echo "== Done: SeekZip $VERSION =="
echo "  app: $APP"
echo "  dmg: $DMG"
echo "  zip: $ZIP"
echo ""
echo "SHA-256 for the Homebrew files (packaging/homebrew/):"
echo "  DMG (cask):        $(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "  source tarball:    fill in after 'git tag v$VERSION' + GitHub release"
echo "                     (see docs/RELEASE.md step 7)"
echo ""
echo "Next: create the GitHub release (tag v$VERSION), upload the DMG,"
echo "then copy packaging/homebrew/{Formula,Casks} into the"
echo "TranManhTuanLabs/homebrew-seekzip tap with the DMG SHA-256 above."
