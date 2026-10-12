#!/bin/bash
# Builds a universal PortHole DMG into build/release/.
#
#   scripts/release.sh --adhoc            # ad-hoc signed; needs no Apple account (used by CI)
#   scripts/release.sh                    # Developer ID signed + notarized + stapled, plus Homebrew cask
#   scripts/release.sh --skip-notarize    # Developer ID signed, not notarized (local testing)
#   … --publish                           # also upload the DMG as a GitHub release (gh CLI)
#
# Ad-hoc builds work fully but macOS asks users to approve them once
# (System Settings › Privacy & Security › Open Anyway). Developer ID builds
# need, once:
#   - a "Developer ID Application" certificate for DEVELOPMENT_TEAM (project.yml)
#   - notarization credentials in the keychain:
#       xcrun notarytool store-credentials porthole-notary \
#         --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
set -euo pipefail

NOTARY_PROFILE="${NOTARY_PROFILE:-porthole-notary}"
GITHUB_REPO="${GITHUB_REPO:-arunesh-singh/PortHole}"
MODE=developer-id
NOTARIZE=1
PUBLISH=0
for arg in "$@"; do
    case "$arg" in
        --adhoc) MODE=adhoc; NOTARIZE=0 ;;
        --skip-notarize) NOTARIZE=0 ;;
        --publish) PUBLISH=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done
if [ $PUBLISH = 1 ] && [ $MODE = developer-id ] && [ $NOTARIZE = 0 ]; then
    echo "error: refusing to publish a Developer ID build that is not notarized" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
cd "$ROOT"

step() { printf '\n==> %s\n' "$*"; }

notarize() { # file
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m \
        | tee "$OUT/notary.log"
    grep -q "status: Accepted" "$OUT/notary.log" || {
        id=$(awk '/^  id:/ {print $2; exit}' "$OUT/notary.log")
        [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE"
        exit 1
    }
}

[ -f Vendor/lib/libmtp.a ] || { step "Building libusb + libmtp"; scripts/build-deps.sh; }

step "Generating project"
xcodegen generate --quiet
rm -rf "$OUT" && mkdir -p "$OUT"

if [ $MODE = adhoc ]; then
    step "Building (universal, ad-hoc signed)"
    xcodebuild build -project PortHole.xcodeproj -scheme PortHole -configuration Release \
        -derivedDataPath "$OUT/dd" -destination 'generic/platform=macOS' \
        ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
        CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" -quiet
    APP="$OUT/dd/Build/Products/Release/PortHole.app"
else
    step "Archiving (universal)"
    xcodebuild archive -project PortHole.xcodeproj -scheme PortHole -configuration Release \
        -archivePath "$OUT/PortHole.xcarchive" -destination 'generic/platform=macOS' \
        -allowProvisioningUpdates ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO -quiet

    step "Exporting with Developer ID"
    xcodebuild -exportArchive -archivePath "$OUT/PortHole.xcarchive" \
        -exportOptionsPlist scripts/ExportOptions.plist -exportPath "$OUT/export" \
        -allowProvisioningUpdates -quiet
    APP="$OUT/export/PortHole.app"
    IDENTITY=$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=Developer ID Application/ {print $2; exit}')
    [ -n "$IDENTITY" ] || { echo "error: export is not Developer ID signed" >&2; exit 1; }
fi
codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")

if [ $NOTARIZE = 1 ]; then
    step "Notarizing app"
    ditto -c -k --keepParent "$APP" "$OUT/PortHole.zip"
    notarize "$OUT/PortHole.zip"
    xcrun stapler staple "$APP"
fi

step "Building DMG"
DMG="$OUT/PortHole-$VERSION.dmg"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "PortHole" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" -quiet
[ $MODE = developer-id ] && codesign --sign "$IDENTITY" --timestamp "$DMG"

if [ $NOTARIZE = 1 ]; then
    step "Notarizing DMG"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
fi
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)

if [ $NOTARIZE = 1 ]; then
    step "Writing Homebrew cask"
    cat > "$OUT/porthole.rb" <<EOF
cask "porthole" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$GITHUB_REPO/releases/download/v#{version}/PortHole-#{version}.dmg"
  name "PortHole"
  desc "Mount Android phones in Finder over MTP or ADB"
  homepage "https://github.com/$GITHUB_REPO"

  depends_on macos: ">= :sonoma"

  app "PortHole.app"

  zap trash: [
    "~/Library/Application Support/PortHole",
    "~/Library/Preferences/com.arunesh.porthole.plist",
  ]
end
EOF
fi

if [ $PUBLISH = 1 ]; then
    step "Publishing GitHub release v$VERSION"
    NOTES="$OUT/notes.md"
    if [ $MODE = adhoc ]; then
        cat > "$NOTES" <<'EOF'
**Install:** download `PortHole-*.dmg` below, open it, and drag PortHole into Applications.

This build is not notarized by Apple, so the first launch needs one extra step:
open PortHole, click **Done** on the warning, then go to **System Settings › Privacy & Security** and click **Open Anyway**.
See the [User Guide](https://github.com/GITHUB_REPO/blob/main/docs/USER_GUIDE.md) for details.

SHA-256: `SHA_VALUE`
EOF
        sed -i '' -e "s|GITHUB_REPO|$GITHUB_REPO|" -e "s|SHA_VALUE|$SHA|" "$NOTES"
        gh release create "v$VERSION" "$DMG" --repo "$GITHUB_REPO" --title "PortHole $VERSION" \
            --notes-file "$NOTES"
    else
        gh release create "v$VERSION" "$DMG" --repo "$GITHUB_REPO" --title "PortHole $VERSION" --generate-notes
    fi
fi

step "Done"
echo "DMG:    $DMG"
echo "sha256: $SHA"
[ -f "$OUT/porthole.rb" ] && echo "Cask:   $OUT/porthole.rb"
exit 0
