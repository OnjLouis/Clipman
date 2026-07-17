#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${CLIPMAN_MAC_BUILD_DIR:-/tmp/ClipmanMac-build}"
APP="${CLIPMAN_MAC_APP:-$ROOT/build/Clipman.app}"
VERSION="$(zsh "$ROOT/Scripts/shared-version.sh" version)"
BUILD_VERSION="$(zsh "$ROOT/Scripts/shared-version.sh" build)"
BUILD_STAMP="$(zsh "$ROOT/Scripts/shared-version.sh" stamp)"

swift build --package-path "$ROOT" --scratch-path "$SCRATCH"
swift run --package-path "$ROOT" --scratch-path "$SCRATCH" ClipmanCodecSmoke
swift run --package-path "$ROOT" --scratch-path "$SCRATCH" ClipmanSyncSmoke
swift run --package-path "$ROOT" --scratch-path "$SCRATCH" ClipmanFileHistorySmoke
BIN_DIR="$(swift build --package-path "$ROOT" --scratch-path "$SCRATCH" --show-bin-path)"

rm -rf "$APP"
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
  <string>com.andrelouis.clipman.dev</string>
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

codesign --force --sign - "$APP" >/tmp/clipmanmac-codesign.log 2>&1 || true

if [[ "${1:-}" == "--restart" ]]; then
  pkill -f "$APP/Contents/MacOS/Clipman|swift run.*Clipman" 2>/dev/null || true
  open -n "$APP" || (nohup "$APP/Contents/MacOS/Clipman" >/tmp/clipmanmac.log 2>&1 &)
fi

echo "$APP"
