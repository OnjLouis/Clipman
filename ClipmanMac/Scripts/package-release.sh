#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${CLIPMAN_MAC_RELEASE_BUILD_DIR:-/tmp/ClipmanMac-release-build}"
DIST="${CLIPMAN_MAC_DIST_DIR:-/tmp/ClipmanMac-dist}"
APP="$DIST/Clipman.app"
VERSION="$(zsh "$ROOT/Scripts/shared-version.sh" version)"
BUILD_VERSION="$(zsh "$ROOT/Scripts/shared-version.sh" build)"
BUILD_STAMP="$(zsh "$ROOT/Scripts/shared-version.sh" stamp)"
ZIP="$DIST/Clipman-macOS-$VERSION.zip"
SIGNING_IDENTITY="${CLIPMAN_MAC_SIGNING_IDENTITY:-Developer ID Application: Andre Louis (83NN3HS237)}"
EXPECTED_TEAM_ID="83NN3HS237"
NOTARY_PROFILE="${CLIPMAN_MAC_NOTARY_PROFILE:-ClipmanNotary}"
NOTARY_KEYCHAIN="${CLIPMAN_MAC_NOTARY_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
NOTARIZE="${CLIPMAN_MAC_NOTARIZE:-1}"

if [[ "$NOTARIZE" == "1" ]]; then
  if ! xcrun notarytool history \
      --keychain-profile "$NOTARY_PROFILE" \
      --keychain "$NOTARY_KEYCHAIN" >/dev/null 2>&1; then
    echo "Mac notarization credential '$NOTARY_PROFILE' is unavailable in $NOTARY_KEYCHAIN." >&2
    echo "Store or repair the credential before running the release package." >&2
    exit 1
  fi
fi

rm -rf "$DIST"
mkdir -p "$DIST"

swift build --package-path "$ROOT" --scratch-path "$SCRATCH" --configuration release
swift run --package-path "$ROOT" --scratch-path "$SCRATCH" --configuration release ClipmanCodecSmoke
swift run --package-path "$ROOT" --scratch-path "$SCRATCH" --configuration release ClipmanSyncSmoke
swift run --package-path "$ROOT" --scratch-path "$SCRATCH" --configuration release ClipmanFileHistorySmoke

BIN_DIR="$(swift build --package-path "$ROOT" --scratch-path "$SCRATCH" --configuration release --show-bin-path)"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Clipman" "$APP/Contents/MacOS/Clipman"
cp -R "$ROOT/Sources/Clipman/Resources/sounds" "$APP/Contents/Resources/sounds"
cp "$ROOT/../Manual.html" "$APP/Contents/Resources/Manual.html"
cp "$ROOT/../LICENSE.txt" "$APP/Contents/Resources/LICENSE.txt"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Clipman</string>
  <key>CFBundleIdentifier</key>
  <string>com.andrelouis.clipman</string>
  <key>CFBundleName</key>
  <string>Clipman</string>
  <key>CFBundleDisplayName</key>
  <string>Clipman</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_VERSION</string>
  <key>ClipmanBuildStampUtcMs</key>
  <string>$BUILD_STAMP</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
</dict>
</plist>
PLIST

if ! security find-identity -v -p codesigning | grep -Fq "\"$SIGNING_IDENTITY\""; then
  echo "Required Mac release signing identity is unavailable: $SIGNING_IDENTITY" >&2
  exit 1
fi

codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

SIGNATURE_DETAILS="$(codesign -dvv "$APP" 2>&1)"
if [[ "$SIGNATURE_DETAILS" != *"TeamIdentifier=$EXPECTED_TEAM_ID"* ]]; then
  echo "Mac release signature does not use expected team $EXPECTED_TEAM_ID." >&2
  exit 1
fi
if [[ "$SIGNATURE_DETAILS" == *"Signature=adhoc"* ]]; then
  echo "Mac release must not be ad-hoc signed." >&2
  exit 1
fi

(
  cd "$DIST"
  COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "Clipman.app" "$ZIP"
)

if [[ "$NOTARIZE" == "1" ]]; then
  xcrun notarytool submit "$ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --keychain "$NOTARY_KEYCHAIN" \
    --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  rm -f "$ZIP"
  (
    cd "$DIST"
    COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "Clipman.app" "$ZIP"
  )
  spctl --assess --type execute --verbose=4 "$APP"
else
  echo "Warning: Mac test package was not notarized because CLIPMAN_MAC_NOTARIZE=$NOTARIZE." >&2
fi

echo "$ZIP"
