#!/usr/bin/env sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this installer as root, for example with sudo." >&2
  exit 1
fi

APP_DIR="${CLIPMAN_SERVER_APP_DIR:-}"
CONFIG_FILE="${CLIPMAN_SERVER_CONFIG_FILE:-}"
SERVICE="${CLIPMAN_SERVER_SERVICE:-}"
if [ -n "${CLIPMAN_SERVER_INIT_SYSTEM:-}" ]; then
  INIT_SYSTEM="$CLIPMAN_SERVER_INIT_SYSTEM"
elif [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  INIT_SYSTEM=systemd
elif command -v sv >/dev/null 2>&1; then
  INIT_SYSTEM=runit
else
  echo "Could not detect systemd or runit." >&2
  exit 1
fi
case "$INIT_SYSTEM" in
  systemd) DEFAULT_SERVICE_FILE="/etc/systemd/system/$SERVICE" ;;
  runit) DEFAULT_SERVICE_FILE="/etc/sv/$SERVICE" ;;
  *) echo "Unsupported CLIPMAN_SERVER_INIT_SYSTEM: $INIT_SYSTEM (use systemd or runit)." >&2; exit 2 ;;
esac
SERVICE_FILE="${CLIPMAN_SERVER_SERVICE_FILE:-$DEFAULT_SERVICE_FILE}"
HELPER="${CLIPMAN_SERVER_HELPER:-/usr/local/sbin/clipmanserver}"
LAUNCHER="${CLIPMAN_SERVER_LAUNCHER:-/usr/local/libexec/clipman-server-managed}"
MANAGER_CONFIG="${CLIPMAN_SERVER_MANAGER_CONFIG:-/etc/clipman-server-manager.conf}"
SYSTEMD_DIR="${CLIPMAN_SERVER_SYSTEMD_DIR:-/etc/systemd/system}"
SYSTEMCTL="${CLIPMAN_SERVER_SYSTEMCTL:-systemctl}"
SV="${CLIPMAN_SERVER_SV:-sv}"
RUNIT_SERVICE_DIR="${CLIPMAN_SERVER_RUNIT_SERVICE_DIR:-/etc/sv}"
RUNIT_ACTIVE_DIR="${CLIPMAN_SERVER_RUNIT_ACTIVE_DIR:-/var/service}"

for value in "$APP_DIR" "$CONFIG_FILE" "$SERVICE" "$SERVICE_FILE" "$HELPER" "$LAUNCHER" "$MANAGER_CONFIG" "$SYSTEMD_DIR" "$SYSTEMCTL" "$SV" "$RUNIT_SERVICE_DIR" "$RUNIT_ACTIVE_DIR"; do
  case "$value" in
    ""|*"'"*|*"
"*) echo "System-managed Clipman Server paths and service names must be non-empty and cannot contain quotes or newlines." >&2; exit 2 ;;
  esac
done

case "$APP_DIR:$CONFIG_FILE:$SERVICE_FILE:$HELPER:$LAUNCHER:$MANAGER_CONFIG:$SYSTEMD_DIR:$RUNIT_SERVICE_DIR:$RUNIT_ACTIVE_DIR" in
  /*:/*:/*:/*:/*:/*:/*:/*:/*) ;;
  *) echo "System-managed Clipman Server paths must be absolute." >&2; exit 2 ;;
esac
case "$SERVICE" in
  *[!A-Za-z0-9_.@-]*|"") echo "Invalid service name: $SERVICE" >&2; exit 2 ;;
esac

for required in "$APP_DIR/clipman_server.py" "$APP_DIR/clipman_server_updater.py" "$CONFIG_FILE"; do
  if [ ! -f "$required" ]; then
    echo "Required existing server file was not found: $required" >&2
    exit 1
  fi
done
if [ "$INIT_SYSTEM" = systemd ] && [ ! -f "$SERVICE_FILE" ]; then
  echo "Required existing systemd unit was not found: $SERVICE_FILE" >&2; exit 1
fi
if [ "$INIT_SYSTEM" = runit ] && [ ! -x "$SERVICE_FILE/run" ]; then
  echo "Required existing runit service was not found: $SERVICE_FILE/run" >&2; exit 1
fi
if [ "$INIT_SYSTEM" = systemd ] && ! command -v "$SYSTEMCTL" >/dev/null 2>&1; then
  echo "systemctl was not found." >&2; exit 1
fi
if [ "$INIT_SYSTEM" = runit ] && ! command -v "$SV" >/dev/null 2>&1; then
  echo "sv was not found." >&2; exit 1
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
CLIPMAN_SERVER_INIT_SYSTEM='$INIT_SYSTEM'
CLIPMAN_SERVER_SV='$SV'
CLIPMAN_SERVER_RUNIT_SERVICE_DIR='$RUNIT_SERVICE_DIR'
CLIPMAN_SERVER_RUNIT_ACTIVE_DIR='$RUNIT_ACTIVE_DIR'
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
INIT_SYSTEM="$CLIPMAN_SERVER_INIT_SYSTEM"
SV="$CLIPMAN_SERVER_SV"
RUNIT_SERVICE_DIR="$CLIPMAN_SERVER_RUNIT_SERVICE_DIR"
RUNIT_ACTIVE_DIR="$CLIPMAN_SERVER_RUNIT_ACTIVE_DIR"

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

service_action() {
  action="$1"
  if [ "$INIT_SYSTEM" = systemd ]; then
    case "$action" in
      start) "$SYSTEMCTL" daemon-reload; "$SYSTEMCTL" enable --now "$SERVICE" ;;
      status) "$SYSTEMCTL" status "$SERVICE" --no-pager ;;
      *) "$SYSTEMCTL" "$action" "$SERVICE" ;;
    esac
  else
    case "$action" in
      start) rm -f "$SERVICE_FILE/down"; [ -e "$RUNIT_ACTIVE_DIR/$SERVICE" ] || ln -s "$SERVICE_FILE" "$RUNIT_ACTIVE_DIR/$SERVICE"; "$SV" up "$SERVICE_FILE" ;;
      stop) "$SV" down "$SERVICE_FILE" ;;
      restart) "$SV" restart "$SERVICE_FILE" ;;
      status) "$SV" status "$SERVICE_FILE" ;;
    esac
  fi
}

case "${1:-help}" in
  start) require_root; service_action start ;;
  stop) require_root; service_action stop ;;
  restart) require_root; service_action restart ;;
  status) service_action status ;;
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
    service_action stop
    if ! "$SERVER" --port "$PORT" --write-connection-info; then
      service_action start
      exit 1
    fi
    service_action start
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
  cert) require_root; shift; "$SERVER" --create-tls-certificate "$@"; service_action restart ;;
  fingerprint) require_root; "$SERVER" --show-ca-fingerprint ;;
  share-ca) require_root; shift; "$SERVER" --share-ca "$@" ;;
  enable-auto-updates)
    require_root
    if [ "$INIT_SYSTEM" = systemd ]; then "$SYSTEMCTL" daemon-reload; "$SYSTEMCTL" enable --now "${SERVICE%.service}-update.timer"
    else rm -f "$RUNIT_SERVICE_DIR/${SERVICE%.service}-update/down"; [ -e "$RUNIT_ACTIVE_DIR/${SERVICE%.service}-update" ] || ln -s "$RUNIT_SERVICE_DIR/${SERVICE%.service}-update" "$RUNIT_ACTIVE_DIR/${SERVICE%.service}-update"; "$SV" up "$RUNIT_SERVICE_DIR/${SERVICE%.service}-update"; fi
    ;;
  disable-auto-updates)
    require_root
    if [ "$INIT_SYSTEM" = systemd ]; then "$SYSTEMCTL" disable --now "${SERVICE%.service}-update.timer" 2>/dev/null || true
    else : > "$RUNIT_SERVICE_DIR/${SERVICE%.service}-update/down"; "$SV" down "$RUNIT_SERVICE_DIR/${SERVICE%.service}-update" 2>/dev/null || true; fi
    ;;
  update-status)
    if [ "$INIT_SYSTEM" = systemd ]; then "$SYSTEMCTL" status "${SERVICE%.service}-update.timer" --no-pager
    else "$SV" status "$RUNIT_SERVICE_DIR/${SERVICE%.service}-update"; fi
    ;;
  help|-h|--help) usage ;;
  *) usage; exit 2 ;;
esac
HELPER_SCRIPT
chmod 755 "$temporary_helper"
mv -f "$temporary_helper" "$HELPER"

unit_base="${SERVICE%.service}-update"
if [ "$INIT_SYSTEM" = systemd ]; then
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
else
  update_dir="$RUNIT_SERVICE_DIR/$unit_base"
  mkdir -p "$update_dir"
  cat > "$update_dir/run" <<EOF
#!/usr/bin/env sh
exec 2>&1
set -e
while :; do
  sleep 900
  $HELPER update --yes || true
  sleep 85500
done
EOF
  chmod 755 "$update_dir/run"
  : > "$update_dir/down"
fi

echo "System management installed without changing the running server, its service, or its data."
echo "Helper: $HELPER"
echo "Current server version: $($LAUNCHER --version)"
echo "Check for an update with: sudo $HELPER check-update"
echo "Install an update with: sudo $HELPER update"
