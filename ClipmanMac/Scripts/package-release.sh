#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${CLIPMAN_MAC_RELEASE_BUILD_DIR:-/tmp/ClipmanMac-release-build}"
DIST="${CLIPMAN_MAC_DIST_DIR:-$ROOT/dist}"
APP="$DIST/Clipman.app"
ZIP="$DIST/ClipmanMac.zip"
VERSION="$(zsh "$ROOT/Scripts/shared-version.sh" version)"
BUILD_VERSION="$(zsh "$ROOT/Scripts/shared-version.sh" build)"

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
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/tmp/clipmanmac-release-codesign.log 2>&1 || true

(
  cd "$DIST"
  COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "Clipman.app" "$ZIP"
)

echo "$ZIP"
