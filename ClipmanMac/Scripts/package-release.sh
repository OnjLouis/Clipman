#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_ROOT="${CLIPMAN_TEMP_ROOT:-$HOME/Projects/Codex/Temp/clipman}"
SCRATCH="${CLIPMAN_MAC_RELEASE_BUILD_DIR:-$TEMP_ROOT/mac-release-build}"
DIST="${CLIPMAN_MAC_DIST_DIR:-$TEMP_ROOT/mac-release-dist}"
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
NOTARY_TIMEOUT_SECONDS="${CLIPMAN_MAC_NOTARY_TIMEOUT_SECONDS:-1800}"
NOTARY_POLL_SECONDS="${CLIPMAN_MAC_NOTARY_POLL_SECONDS:-10}"
RESUME_SUBMISSION_ID="${CLIPMAN_MAC_RESUME_SUBMISSION_ID:-}"
completed=false

remove_owned_tree() {
  local tree="$1"
  if [[ -z "$tree" || "$tree" == "/" || "$tree" == "$HOME" || "$tree" == "$ROOT" ]]; then
    echo "Refusing to clean unsafe Clipman build path: $tree" >&2
    return 1
  fi
  /bin/rm -rf "$tree"
}

cleanup_build() {
  local exit_code=$?
  trap - EXIT
  remove_owned_tree "$SCRATCH" || exit_code=1
  if [[ "$completed" != true ]]; then
    remove_owned_tree "$DIST" || exit_code=1
  fi
  exit "$exit_code"
}
trap cleanup_build EXIT

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
  SUBMISSION_JSON="$SCRATCH/notary-submission.json"
  SUBMISSION_ERROR="$SCRATCH/notary-submission.err"
  HISTORY_JSON="$SCRATCH/notary-history.json"
  HISTORY_ERROR="$SCRATCH/notary-history.err"
  INFO_JSON="$SCRATCH/notary-info.json"
  INFO_ERROR="$SCRATCH/notary-info.err"
  SUBMISSION_NAME="$(basename "$ZIP")"
  SUBMIT_STARTED_EPOCH="$(date -u +%s)"
  SUBMISSION_ID="$RESUME_SUBMISSION_ID"
  if [[ -n "$SUBMISSION_ID" ]]; then
    echo "Resuming Apple notarization submission $SUBMISSION_ID."
  elif xcrun notarytool submit "$ZIP" \
      --keychain-profile "$NOTARY_PROFILE" \
      --keychain "$NOTARY_KEYCHAIN" \
      --output-format json >"$SUBMISSION_JSON" 2>"$SUBMISSION_ERROR"; then
    SUBMISSION_ID="$(plutil -extract id raw -o - "$SUBMISSION_JSON" 2>/dev/null || true)"
  else
    echo "Apple notarization submission response failed; checking whether Apple received the upload." >&2
    cat "$SUBMISSION_ERROR" >&2
  fi

  if [[ -z "$SUBMISSION_ID" ]]; then
    for _ in {1..6}; do
      if xcrun notarytool history \
          --keychain-profile "$NOTARY_PROFILE" \
          --keychain "$NOTARY_KEYCHAIN" \
          --output-format json >"$HISTORY_JSON" 2>"$HISTORY_ERROR"; then
        SUBMISSION_ID="$(/usr/bin/python3 - "$HISTORY_JSON" "$SUBMISSION_NAME" "$SUBMIT_STARTED_EPOCH" <<'PY'
import datetime
import json
import sys

history_path, expected_name, started_epoch = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(history_path, encoding="utf-8") as source:
    history = json.load(source).get("history", [])
for item in history:
    if item.get("name") != expected_name or not item.get("id"):
        continue
    created = str(item.get("createdDate", "")).replace("Z", "+00:00")
    try:
        created_epoch = datetime.datetime.fromisoformat(created).timestamp()
    except ValueError:
        continue
    if created_epoch >= started_epoch - 30:
        print(item["id"])
        break
PY
)"
        if [[ -n "$SUBMISSION_ID" ]]; then
          echo "Recovered Apple notarization submission $SUBMISSION_ID from submission history."
          break
        fi
      else
        echo "Apple notarization history check failed temporarily; retrying." >&2
        cat "$HISTORY_ERROR" >&2
      fi
      sleep "$NOTARY_POLL_SECONDS"
    done
  fi
  if [[ -z "$SUBMISSION_ID" ]]; then
    echo "Apple notarization did not return a submission ID." >&2
    exit 1
  fi

  echo "Waiting for Apple notarization submission $SUBMISSION_ID."
  NOTARY_DEADLINE=$((SECONDS + NOTARY_TIMEOUT_SECONDS))
  NOTARY_STATUS="In Progress"
  while (( SECONDS < NOTARY_DEADLINE )); do
    if xcrun notarytool info "$SUBMISSION_ID" \
        --keychain-profile "$NOTARY_PROFILE" \
        --keychain "$NOTARY_KEYCHAIN" \
        --output-format json >"$INFO_JSON" 2>"$INFO_ERROR"; then
      NOTARY_STATUS="$(plutil -extract status raw -o - "$INFO_JSON")"
      case "$NOTARY_STATUS" in
        Accepted)
          break
          ;;
        Invalid|Rejected)
          cat "$INFO_JSON" >&2
          xcrun notarytool log "$SUBMISSION_ID" \
            --keychain-profile "$NOTARY_PROFILE" \
            --keychain "$NOTARY_KEYCHAIN" >&2 || true
          exit 1
          ;;
      esac
    else
      echo "Apple notarization status check failed temporarily; retrying." >&2
      cat "$INFO_ERROR" >&2
    fi
    sleep "$NOTARY_POLL_SECONDS"
  done
  if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    echo "Apple notarization did not finish within $NOTARY_TIMEOUT_SECONDS seconds; last status: $NOTARY_STATUS." >&2
    exit 1
  fi

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

completed=true
echo "$ZIP"
