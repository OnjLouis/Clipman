#!/usr/bin/env sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this installer as root, for example with sudo." >&2
  exit 1
fi

APP_DIR="${CLIPMAN_SERVER_APP_DIR:-}"
CONFIG_FILE="${CLIPMAN_SERVER_CONFIG_FILE:-}"
SERVICE="${CLIPMAN_SERVER_SERVICE:-}"
SERVICE_FILE="${CLIPMAN_SERVER_SERVICE_FILE:-/etc/systemd/system/$SERVICE}"
HELPER="${CLIPMAN_SERVER_HELPER:-/usr/local/sbin/clipmanserver}"
LAUNCHER="${CLIPMAN_SERVER_LAUNCHER:-/usr/local/libexec/clipman-server-managed}"
MANAGER_CONFIG="${CLIPMAN_SERVER_MANAGER_CONFIG:-/etc/clipman-server-manager.conf}"
SYSTEMD_DIR="${CLIPMAN_SERVER_SYSTEMD_DIR:-/etc/systemd/system}"
SYSTEMCTL="${CLIPMAN_SERVER_SYSTEMCTL:-systemctl}"

for value in "$APP_DIR" "$CONFIG_FILE" "$SERVICE" "$SERVICE_FILE" "$HELPER" "$LAUNCHER" "$MANAGER_CONFIG" "$SYSTEMD_DIR" "$SYSTEMCTL"; do
  case "$value" in
    ""|*"'"*|*"
"*) echo "System-managed Clipman Server paths and service names must be non-empty and cannot contain quotes or newlines." >&2; exit 2 ;;
  esac
done

case "$APP_DIR:$CONFIG_FILE:$SERVICE_FILE:$HELPER:$LAUNCHER:$MANAGER_CONFIG:$SYSTEMD_DIR" in
  /*:/*:/*:/*:/*:/*:/*) ;;
  *) echo "System-managed Clipman Server paths must be absolute." >&2; exit 2 ;;
esac
case "$SERVICE" in
  *[!A-Za-z0-9_.@-]*|"") echo "Invalid systemd service name: $SERVICE" >&2; exit 2 ;;
esac

for required in "$APP_DIR/clipman_server.py" "$APP_DIR/clipman_server_updater.py" "$CONFIG_FILE" "$SERVICE_FILE"; do
  if [ ! -f "$required" ]; then
    echo "Required existing server file was not found: $required" >&2
    exit 1
  fi
done
if ! command -v "$SYSTEMCTL" >/dev/null 2>&1; then
  echo "A system-managed installation requires systemd." >&2
  exit 1
fi

mkdir -p "$(dirname "$HELPER")" "$(dirname "$LAUNCHER")" "$(dirname "$MANAGER_CONFIG")"

temporary_config="$MANAGER_CONFIG.new"
cat > "$temporary_config" <<EOF
CLIPMAN_SERVER_APP_DIR='$APP_DIR'
CLIPMAN_SERVER_CONFIG_FILE='$CONFIG_FILE'
CLIPMAN_SERVER_SERVICE='$SERVICE'
CLIPMAN_SERVER_SERVICE_FILE='$SERVICE_FILE'
CLIPMAN_SERVER_HELPER='$HELPER'
CLIPMAN_SERVER_LAUNCHER='$LAUNCHER'
CLIPMAN_SERVER_SYSTEMD_DIR='$SYSTEMD_DIR'
CLIPMAN_SERVER_SYSTEMCTL='$SYSTEMCTL'
EOF
chmod 600 "$temporary_config"
mv -f "$temporary_config" "$MANAGER_CONFIG"

temporary_launcher="$LAUNCHER.new"
cat > "$temporary_launcher" <<EOF
#!/usr/bin/env sh
exec python3 '$APP_DIR/clipman_server.py' --config '$CONFIG_FILE' "\$@"
EOF
chmod 755 "$temporary_launcher"
mv -f "$temporary_launcher" "$LAUNCHER"

temporary_helper="$HELPER.new"
cat > "$temporary_helper" <<EOF
#!/usr/bin/env sh
DEFAULT_MANAGER_CONFIG='$MANAGER_CONFIG'
EOF
cat >> "$temporary_helper" <<'HELPER_SCRIPT'
set -eu

MANAGER_CONFIG="${CLIPMAN_SERVER_MANAGER_CONFIG:-$DEFAULT_MANAGER_CONFIG}"
if [ ! -r "$MANAGER_CONFIG" ]; then
  echo "Clipman Server manager configuration is unavailable: $MANAGER_CONFIG" >&2
  exit 1
fi
. "$MANAGER_CONFIG"

UPDATER="$CLIPMAN_SERVER_APP_DIR/clipman_server_updater.py"
SERVER="$CLIPMAN_SERVER_LAUNCHER"
SERVICE="$CLIPMAN_SERVER_SERVICE"
SERVICE_FILE="$CLIPMAN_SERVER_SERVICE_FILE"
HELPER="$CLIPMAN_SERVER_HELPER"
CONFIG="$CLIPMAN_SERVER_CONFIG_FILE"
APP_DIR="$CLIPMAN_SERVER_APP_DIR"
BIN_DIR="$(dirname "$HELPER")"
SYSTEMD_DIR="$CLIPMAN_SERVER_SYSTEMD_DIR"
SYSTEMCTL="$CLIPMAN_SERVER_SYSTEMCTL"

usage() {
  cat <<'USAGE'
Usage: clipmanserver <command>

Commands:
  start, stop, restart, status
  version, check-update, update
  host [listening-address] [client-address]
  port [number]
  token, connection, console
  list, list-json, prune [days], delete <id>, force-delete <id>
  cert [certificate options], fingerprint, share-ca [options]
  enable-auto-updates, disable-auto-updates, update-status
  help
USAGE
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "This command manages a system service; run it with sudo." >&2
    exit 1
  fi
}

server_version() {
  "$SERVER" --version
}

updater() {
  python3 "$UPDATER" "$@" \
    --current-version "$(server_version)" \
    --app-dir "$APP_DIR" --bin-dir "$BIN_DIR" --config "$CONFIG" \
    --service-file "$SERVICE_FILE" --helper-path "$HELPER" \
    --launcher-path "$SERVER" --managed-program-only
}

case "${1:-help}" in
  start) require_root; "$SYSTEMCTL" daemon-reload; "$SYSTEMCTL" enable --now "$SERVICE" ;;
  stop) require_root; "$SYSTEMCTL" stop "$SERVICE" ;;
  restart) require_root; "$SYSTEMCTL" restart "$SERVICE" ;;
  status) "$SYSTEMCTL" status "$SERVICE" --no-pager ;;
  version) server_version ;;
  check-update) updater --check ;;
  update) require_root; shift; updater --install "$@" ;;
  host)
    HOST="${2:-}"
    if [ -z "$HOST" ]; then
      python3 - "$CONFIG" <<'PY'
import json, sys
from pathlib import Path
settings = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
print(settings.get("Host", "127.0.0.1"))
PY
      exit 0
    fi
    require_root
    if [ -n "${3:-}" ]; then
      updater --set-host "$HOST" --advertise-host "$3"
    else
      updater --set-host "$HOST"
    fi
    ;;
  port)
    require_root
    PORT="${2:-}"
    if [ -z "$PORT" ]; then
      PORT="$($SERVER --suggest-port)"
      printf "Use suggested listening port %s? [y/N] " "$PORT"
      read -r ANSWER
      case "$ANSWER" in y|Y|yes|YES) ;; *) exit 0 ;; esac
    fi
    case "$PORT" in *[!0-9]*|'') echo "Port must be a number between 1024 and 49151." >&2; exit 2 ;; esac
    if [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 49151 ]; then
      echo "Port must be between 1024 and 49151." >&2
      exit 2
    fi
    "$SYSTEMCTL" stop "$SERVICE"
    if ! "$SERVER" --port "$PORT" --write-connection-info; then
      "$SYSTEMCTL" start "$SERVICE"
      exit 1
    fi
    "$SYSTEMCTL" start "$SERVICE"
    echo "Clipman Server now uses port $PORT."
    ;;
  token) require_root; "$SERVER" --show-token ;;
  connection) require_root; "$SERVER" --write-connection-info ;;
  console) require_root; exec "$SERVER" ;;
  list) require_root; "$SERVER" --list-databases ;;
  list-json) require_root; "$SERVER" --list-databases-json ;;
  prune)
    require_root
    DAYS="${2:-}"
    if [ -z "$DAYS" ]; then
      DAYS="$(python3 - "$CONFIG" <<'PY'
import json, sys
from pathlib import Path
settings = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
print(settings.get("DatabasePruneDays", 0))
PY
)"
    fi
    if [ -z "$DAYS" ] || [ "$DAYS" = "0" ]; then
      echo "DatabasePruneDays is 0, so stale database cleanup is disabled." >&2
      exit 2
    fi
    "$SERVER" --prune-databases-days "$DAYS" --confirm
    ;;
  delete)
    require_root
    [ -n "${2:-}" ] || { echo "Usage: clipmanserver delete <database-id>" >&2; exit 2; }
    "$SERVER" --delete-database "$2" --confirm
    ;;
  force-delete)
    require_root
    [ -n "${2:-}" ] || { echo "Usage: clipmanserver force-delete <database-id>" >&2; exit 2; }
    "$SERVER" --delete-database "$2" --confirm --force-recent
    ;;
  cert) require_root; shift; "$SERVER" --create-tls-certificate "$@"; "$SYSTEMCTL" restart "$SERVICE" ;;
  fingerprint) require_root; "$SERVER" --show-ca-fingerprint ;;
  share-ca) require_root; shift; "$SERVER" --share-ca "$@" ;;
  enable-auto-updates) require_root; "$SYSTEMCTL" daemon-reload; "$SYSTEMCTL" enable --now "${SERVICE%.service}-update.timer" ;;
  disable-auto-updates) require_root; "$SYSTEMCTL" disable --now "${SERVICE%.service}-update.timer" 2>/dev/null || true ;;
  update-status) "$SYSTEMCTL" status "${SERVICE%.service}-update.timer" --no-pager ;;
  help|-h|--help) usage ;;
  *) usage; exit 2 ;;
esac
HELPER_SCRIPT
chmod 755 "$temporary_helper"
mv -f "$temporary_helper" "$HELPER"

unit_base="${SERVICE%.service}-update"
mkdir -p "$SYSTEMD_DIR"
cat > "$SYSTEMD_DIR/$unit_base.service" <<EOF
[Unit]
Description=Update system-managed Clipman Server
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$HELPER update --yes
EOF

cat > "$SYSTEMD_DIR/$unit_base.timer" <<EOF
[Unit]
Description=Check daily for system-managed Clipman Server updates

[Timer]
OnBootSec=15min
OnUnitActiveSec=1d
RandomizedDelaySec=2h
Persistent=true

[Install]
WantedBy=timers.target
EOF

"$SYSTEMCTL" daemon-reload

echo "System management installed without changing the running server, its service, or its data."
echo "Helper: $HELPER"
echo "Current server version: $($LAUNCHER --version)"
echo "Check for an update with: sudo $HELPER check-update"
echo "Install an update with: sudo $HELPER update"
