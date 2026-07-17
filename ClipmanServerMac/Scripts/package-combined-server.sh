#!/usr/bin/env zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="$(zsh "$ROOT/ClipmanMac/Scripts/shared-version.sh" version)"
DIST="$ROOT/release/Server"
STAGING="$(mktemp -d /tmp/clipman-server-combined.XXXXXX)"
PACKAGE_ROOT="$STAGING/ClipmanServer"
ZIP="$DIST/ClipmanServer-$VERSION.zip"

cleanup() {
  rm -rf "$STAGING"
}
trap cleanup EXIT

mkdir -p "$PACKAGE_ROOT/Windows" "$PACKAGE_ROOT/Linux" "$PACKAGE_ROOT/macOS" "$DIST"

cp "$ROOT/ClipmanServerLinux/clipman_server.py" "$PACKAGE_ROOT/clipman_server.py"
cp "$ROOT/ClipmanServerLinux/install-clipman-server.sh" "$PACKAGE_ROOT/Linux/install-clipman-server.sh"
cp "$ROOT/ClipmanServer/Manual.html" "$PACKAGE_ROOT/Manual.html"
cp "$ROOT/ClipmanServer/clipman-server-settings.example.jsonc" "$PACKAGE_ROOT/clipman-server-settings.example.jsonc"
cp "$ROOT/LICENSE.txt" "$PACKAGE_ROOT/LICENSE.txt"
if [[ -f "$ROOT/ClipmanServerWindows/dist/ClipmanServer.exe" ]]; then
  cp "$ROOT/ClipmanServerWindows/dist/ClipmanServer.exe" "$PACKAGE_ROOT/Windows/Clipman Server.exe"
else
  cp "$ROOT/ClipmanServerWindows/dist/Clipman Server.exe" "$PACKAGE_ROOT/Windows/Clipman Server.exe"
fi

cat > "$PACKAGE_ROOT/Linux/run-clipman-server.sh" <<'SH'
#!/usr/bin/env sh
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR/.."
exec python3 clipman_server.py "$@"
SH
chmod +x "$PACKAGE_ROOT/Linux/run-clipman-server.sh"

MAC_APP="$ROOT/ClipmanServerMac/dist/Clipman Server.app"
if [[ ! -d "$MAC_APP" ]]; then
  echo "Mac Clipman Server app is missing. Run ClipmanServerMac/Scripts/package-release.sh first." >&2
  exit 1
fi
ditto "$MAC_APP" "$PACKAGE_ROOT/macOS/Clipman Server.app"

cat > "$PACKAGE_ROOT/manifest.json" <<JSON
{
  "Name": "Clipman Server",
  "Version": "$VERSION",
  "ServerProgram": "clipman_server.py",
  "Platforms": [
    "Linux",
    "macOS",
    "Windows"
  ],
  "Documentation": [
    "Manual.html",
    "clipman-server-settings.example.jsonc"
  ],
  "WindowsApp": "Windows\\\\Clipman Server.exe",
  "MacApp": "macOS\\\\Clipman Server.app"
}
JSON

rm -f "$ZIP"
ditto -c -k --keepParent "$PACKAGE_ROOT" "$ZIP"
echo "Built $ZIP"
