#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -f "$SCRIPT_DIR/../clipman_server.py" ]; then
  SOURCE_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
elif [ -f "$SCRIPT_DIR/clipman_server.py" ]; then
  SOURCE_ROOT="$SCRIPT_DIR"
else
  echo "Could not find clipman_server.py beside or above this installer." >&2
  exit 1
fi

APP_DIR="${CLIPMAN_SERVER_APP_DIR:-$HOME/.local/lib/clipman-server}"
BIN_DIR="${CLIPMAN_SERVER_BIN_DIR:-$HOME/.local/bin}"
CONFIG_DIR="${CLIPMAN_SERVER_CONFIG_DIR:-$HOME/.config/clipman-server}"
CONFIG_FILE="$CONFIG_DIR/clipman-server-settings.json"
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/clipman-server.service"

mkdir -p "$APP_DIR" "$BIN_DIR" "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR" 2>/dev/null || true

cp "$SOURCE_ROOT/clipman_server.py" "$APP_DIR/clipman_server.py"
chmod 700 "$APP_DIR/clipman_server.py" 2>/dev/null || true

if [ -f "$SOURCE_ROOT/Manual.html" ]; then
  cp "$SOURCE_ROOT/Manual.html" "$APP_DIR/Manual.html"
fi
if [ -f "$SOURCE_ROOT/LICENSE.txt" ]; then
  cp "$SOURCE_ROOT/LICENSE.txt" "$APP_DIR/LICENSE.txt"
fi

cat > "$BIN_DIR/clipman-server" <<EOF
#!/usr/bin/env sh
exec python3 "$APP_DIR/clipman_server.py" --config "$CONFIG_FILE" "\$@"
EOF
chmod 700 "$BIN_DIR/clipman-server" 2>/dev/null || true

cat > "$BIN_DIR/clipmanserver" <<EOF
#!/usr/bin/env sh
set -eu
SERVICE="clipman-server.service"
LAUNCHER="$BIN_DIR/clipman-server"
CONFIG_FILE="$CONFIG_FILE"

usage() {
  cat <<USAGE
Usage: clipmanserver <command>

Commands:
  start       Start Clipman Server
  stop        Stop Clipman Server
  restart     Restart Clipman Server
  status      Show service or process status
  list        List database buckets
  list-json   List database buckets with full IDs as JSON
  prune       Move database buckets inactive for configured or specified days
  delete      Move an inactive database bucket to DeletedDatabases
  force-delete Move a database bucket even if recently active
  console     Run Clipman Server in the current terminal
  token       Print the server token
  connection  Write and print the connection details file path
  help        Show this help
USAGE
}

has_user_service() {
  command -v systemctl >/dev/null 2>&1 && systemctl --user list-unit-files "\$SERVICE" --no-legend 2>/dev/null | grep -q "\$SERVICE"
}

case "\${1:-help}" in
  start)
    if has_user_service; then
      systemctl --user daemon-reload
      systemctl --user enable --now "\$SERVICE"
    else
      nohup "\$LAUNCHER" >/dev/null 2>&1 &
      echo "Clipman Server started."
    fi
    ;;
  stop)
    if has_user_service; then
      systemctl --user stop "\$SERVICE"
    else
      pkill -f "clipman_server.py --config \$CONFIG_FILE" 2>/dev/null || true
    fi
    ;;
  restart)
    "\$0" stop
    "\$0" start
    ;;
  status)
    if has_user_service; then
      systemctl --user status "\$SERVICE" --no-pager
    else
      pgrep -af "clipman_server.py --config \$CONFIG_FILE" || echo "Clipman Server is not running."
    fi
    ;;
  list)
    "\$LAUNCHER" --list-databases
    ;;
  list-json)
    "\$LAUNCHER" --list-databases-json
    ;;
  prune)
    DAYS="\${2:-}"
    if [ -z "\$DAYS" ]; then
      DAYS="\$(python3 - "\$CONFIG_FILE" <<'PY'
import json
import sys
from pathlib import Path

settings = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
print(settings.get("DatabasePruneDays", 0))
PY
)"
    fi
    if [ -z "\$DAYS" ] || [ "\$DAYS" = "0" ]; then
      echo "DatabasePruneDays is 0, so automatic stale database cleanup is disabled." >&2
      echo "Run clipmanserver prune <days> to prune manually." >&2
      exit 2
    fi
    "\$LAUNCHER" --prune-databases-days "\$DAYS" --confirm
    ;;
  delete)
    if [ -z "\${2:-}" ]; then
      echo "Usage: clipmanserver delete <database-id>" >&2
      echo "Tip: run clipmanserver list first, then use --list-databases-json for full IDs." >&2
      exit 2
    fi
    "\$LAUNCHER" --delete-database "\$2" --confirm
    ;;
  force-delete)
    if [ -z "\${2:-}" ]; then
      echo "Usage: clipmanserver force-delete <database-id>" >&2
      echo "This bypasses the 24-hour recent-activity safety guard." >&2
      exit 2
    fi
    "\$LAUNCHER" --delete-database "\$2" --confirm --force-recent
    ;;
  console)
    exec "\$LAUNCHER"
    ;;
  token)
    "\$LAUNCHER" --show-token
    ;;
  connection)
    "\$LAUNCHER" --write-connection-info
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
EOF
chmod 700 "$BIN_DIR/clipmanserver" 2>/dev/null || true

python3 "$APP_DIR/clipman_server.py" --config "$CONFIG_FILE" --write-connection-info >/dev/null

echo "Clipman Server installed."
echo "Program: $APP_DIR/clipman_server.py"
echo "Launcher: $BIN_DIR/clipman-server"
echo "Helper: $BIN_DIR/clipmanserver"
echo "Settings: $CONFIG_FILE"
echo "Connection details: $CONFIG_DIR/clipman-server-connection.txt"
echo
echo "Run now with:"
echo "  clipmanserver start"

if command -v systemctl >/dev/null 2>&1; then
  mkdir -p "$SERVICE_DIR"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Clipman Server
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN_DIR/clipman-server
Restart=always
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=default.target
EOF
  echo
  echo "A user systemd service was written to:"
  echo "  $SERVICE_FILE"
  echo
  echo "Enable it with:"
  echo "  systemctl --user daemon-reload"
  echo "  systemctl --user enable --now clipman-server.service"
  echo
  echo "Or use:"
  echo "  clipmanserver start"
fi
