#!/usr/bin/env zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SERVER_ROOT="$ROOT/ClipmanServerMac"
DIST="$SERVER_ROOT/dist"
APP="$DIST/Clipman Server.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
VERSION="$(zsh "$ROOT/ClipmanMac/Scripts/shared-version.sh" version)"
BUILD_VERSION="$(zsh "$ROOT/ClipmanMac/Scripts/shared-version.sh" build)"

rm -rf "$DIST"
mkdir -p "$MACOS" "$RESOURCES"

swiftc \
  -o "$MACOS/Clipman Server" \
  "$SERVER_ROOT/Sources/ClipmanServer/main.swift" \
  -framework AppKit

cp "$ROOT/ClipmanServerLinux/clipman_server.py" "$RESOURCES/clipman_server.py"
cp "$ROOT/ClipmanServer/Manual.html" "$RESOURCES/Manual.html"
cp "$ROOT/LICENSE.txt" "$RESOURCES/LICENSE.txt"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Clipman Server</string>
  <key>CFBundleIdentifier</key>
  <string>com.andrelouis.clipman-server</string>
  <key>CFBundleName</key>
  <string>Clipman Server</string>
  <key>CFBundleDisplayName</key>
  <string>Clipman Server</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>10.13</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null

ditto -c -k --keepParent "$APP" "$DIST/ClipmanServerMac-$VERSION.zip"
echo "Built $DIST/ClipmanServerMac-$VERSION.zip"
