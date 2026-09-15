#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${1:-${CLIPMAN_TEMP_ROOT:-$HOME/Projects/Codex/Temp/clipman}/debug-logger-smoke}"
HARNESS="$SCRATCH/main.swift"
BINARY="$SCRATCH/debug-logger-smoke"

case "$SCRATCH" in
  "$HOME"/Projects/Codex/Temp/clipman/*) ;;
  *)
    echo "Debug logger smoke scratch must be inside ~/Projects/Codex/Temp/clipman." >&2
    exit 1
    ;;
esac

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"
trap 'rm -rf "$SCRATCH"' EXIT

cat > "$HARNESS" <<'SWIFT'
import Foundation

RuntimeLogger.install()
RuntimeLogger.debug("Debug logger smoke marker.", details: "phase=test")
SWIFT

swiftc -framework AppKit "$ROOT/Sources/Clipman/RuntimeLogger.swift" "$HARNESS" -o "$BINARY"

quiet_output="$(env -u CLIPMAN_DEBUG_LOG "$BINARY" 2>&1)"
if [[ -n "$quiet_output" ]]; then
  echo "Debug logger wrote console output while disabled." >&2
  exit 1
fi

debug_output="$(CLIPMAN_DEBUG_LOG=1 "$BINARY" 2>&1)"
if [[ "$debug_output" != *"Console debug logging enabled."* ||
      "$debug_output" != *"Debug logger smoke marker."* ||
      "$debug_output" != *"phase=test"* ]]; then
  echo "Debug logger did not write the expected opt-in console trace." >&2
  exit 1
fi

echo "Debug logger smoke passed"
