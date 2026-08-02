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

has_turnstile() {
  [ -d /etc/sv/turnstiled ] ||
    [ -e /var/service/turnstiled ] ||
    { command -v xbps-query >/dev/null 2>&1 && xbps-query -p pkgver turnstile >/dev/null 2>&1; }
}

TURNSTILE_MISSING=0
if [ -n "${CLIPMAN_SERVER_INIT_SYSTEM:-}" ]; then
  INIT_SYSTEM="$CLIPMAN_SERVER_INIT_SYSTEM"
elif [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  INIT_SYSTEM=systemd
elif command -v sv >/dev/null 2>&1; then
  if has_turnstile; then
    INIT_SYSTEM=runit
  else
    INIT_SYSTEM=none
    TURNSTILE_MISSING=1
  fi
else
  INIT_SYSTEM=none
fi
case "$INIT_SYSTEM" in
  systemd)
    SERVICE_DIR="${CLIPMAN_SERVER_SERVICE_DIR:-$HOME/.config/systemd/user}"
    SERVICE_FILE="$SERVICE_DIR/clipman-server.service"
    UPDATE_SERVICE_FILE="$SERVICE_DIR/clipman-server-update.service"
    ;;
  runit)
    if ! command -v sv >/dev/null 2>&1; then
      echo "The runit user service requires the sv command." >&2
      exit 1
    fi
    if ! has_turnstile; then
      echo "A per-user runit service requires turnstile." >&2
      if command -v xbps-install >/dev/null 2>&1; then
        echo "Install it on Void Linux with: sudo xbps-install -S turnstile" >&2
      else
        echo "Install and enable turnstile, then run this installer again." >&2
      fi
      exit 1
    fi
    # turnstile's runit backend supervises services placed in ~/.config/service.
    SERVICE_DIR="${CLIPMAN_SERVER_SERVICE_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/service}"
    SERVICE_FILE="$SERVICE_DIR/clipman-server"
    UPDATE_SERVICE_FILE="$SERVICE_DIR/clipman-server-update"
    ;;
  none) SERVICE_DIR=""; SERVICE_FILE="$CONFIG_DIR/clipman-server.service"; UPDATE_SERVICE_FILE="" ;;
  *) echo "Unsupported CLIPMAN_SERVER_INIT_SYSTEM: $INIT_SYSTEM (use systemd or runit)." >&2; exit 2 ;;
esac

mkdir -p "$APP_DIR" "$BIN_DIR" "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR" 2>/dev/null || true

cp "$SOURCE_ROOT/clipman_server.py" "$APP_DIR/clipman_server.py"
chmod 700 "$APP_DIR/clipman_server.py" 2>/dev/null || true
cp "$SOURCE_ROOT/clipman_server_updater.py" "$APP_DIR/clipman_server_updater.py"
chmod 700 "$APP_DIR/clipman_server_updater.py" 2>/dev/null || true

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
APP_DIR="$APP_DIR"
SERVICE_FILE="$SERVICE_FILE"
INIT_SYSTEM="$INIT_SYSTEM"
UPDATE_SERVICE_FILE="$UPDATE_SERVICE_FILE"

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
  host        Show or change the listening host and restart safely
  port        Change the listening port and restart the server
  cert        Create or renew a private-CA HTTPS certificate
  fingerprint Show the private authority SHA-256 fingerprint
  share-ca    Temporarily share the public certificate authority
  version     Show the installed server version
  check-update Check whether a newer server package is available
  update      Safely install a newer server package
  enable-auto-updates Enable daily checked updates
  disable-auto-updates Disable automatic server updates
  update-status Show the automatic update timer status
  help        Show this help

Certificate examples:
  clipmanserver cert
  clipmanserver cert --cert-host server.example
  clipmanserver cert --cert-ip 192.168.1.50
  clipmanserver fingerprint
  clipmanserver share-ca

Listening host examples:
  clipmanserver host 100.64.0.10
  clipmanserver host 0.0.0.0 100.64.0.10
USAGE
}

has_user_service() {
  case "\$INIT_SYSTEM" in
    systemd) command -v systemctl >/dev/null 2>&1 && systemctl --user list-unit-files "\$SERVICE" --no-legend 2>/dev/null | grep -q "\$SERVICE" ;;
    runit) command -v sv >/dev/null 2>&1 && [ -x "\$SERVICE_FILE/run" ] ;;
    *) return 1 ;;
  esac
}

service_command() {
  case "\$INIT_SYSTEM:\$1" in
    systemd:start) systemctl --user daemon-reload; systemctl --user enable --now "\$SERVICE" ;;
    systemd:stop) systemctl --user stop "\$SERVICE" ;;
    systemd:status) systemctl --user status "\$SERVICE" --no-pager ;;
    runit:start) rm -f "\$SERVICE_FILE/down"; sv up "\$SERVICE_FILE" ;;
    runit:stop) touch "\$SERVICE_FILE/down"; sv down "\$SERVICE_FILE" ;;
    runit:status) sv status "\$SERVICE_FILE" ;;
  esac
}

case "\${1:-help}" in
  start)
    if has_user_service; then
      service_command start
    else
      nohup "\$LAUNCHER" >/dev/null 2>&1 &
      echo "Clipman Server started."
    fi
    ;;
  stop)
    if has_user_service; then
      service_command stop
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
      service_command status
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
  host)
    HOST="\${2:-}"
    if [ -z "\$HOST" ]; then
      python3 - "\$CONFIG_FILE" <<'PY'
import json
import sys
from pathlib import Path

settings = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
print(settings.get("Host", "127.0.0.1"))
PY
      exit 0
    fi
    ADVERTISE_HOST="\${3:-}"
    if [ -n "\$ADVERTISE_HOST" ]; then
      exec python3 "\$APP_DIR/clipman_server_updater.py" --set-host "\$HOST" --advertise-host "\$ADVERTISE_HOST" \
        --current-version "\$("\$LAUNCHER" --version)" --app-dir "\$APP_DIR" \
        --bin-dir "$BIN_DIR" --config "\$CONFIG_FILE" --service-file "\$SERVICE_FILE"
    fi
    exec python3 "\$APP_DIR/clipman_server_updater.py" --set-host "\$HOST" \
      --current-version "\$("\$LAUNCHER" --version)" --app-dir "\$APP_DIR" \
      --bin-dir "$BIN_DIR" --config "\$CONFIG_FILE" --service-file "\$SERVICE_FILE"
    ;;
  port)
    PORT="\${2:-}"
    if [ -z "\$PORT" ]; then
      PORT="\$("\$LAUNCHER" --suggest-port)"
      printf "Use suggested listening port %s? [y/N] " "\$PORT"
      read -r ANSWER
      case "\$ANSWER" in y|Y|yes|YES) ;; *) exit 0 ;; esac
    fi
    case "\$PORT" in *[!0-9]*|'') echo "Port must be a number between 1024 and 49151." >&2; exit 2 ;; esac
    if [ "\$PORT" -lt 1024 ] || [ "\$PORT" -gt 49151 ]; then
      echo "Port must be between 1024 and 49151." >&2
      exit 2
    fi
    "\$0" stop
    "\$LAUNCHER" --port "\$PORT" --write-connection-info
    "\$0" start
    echo "Clipman Server now uses port \$PORT. Update each Clipman client's server address or import the refreshed connection file."
    ;;
  cert)
    shift 2>/dev/null || true
    "\$LAUNCHER" --create-tls-certificate "\$@"
    echo
    echo "Restarting Clipman Server to use HTTPS."
    "\$0" restart
    ;;
  fingerprint)
    "\$LAUNCHER" --show-ca-fingerprint
    ;;
  share-ca)
    shift 2>/dev/null || true
    "\$LAUNCHER" --share-ca "\$@"
    ;;
  version)
    "\$LAUNCHER" --version
    ;;
  check-update)
    exec python3 "\$APP_DIR/clipman_server_updater.py" --check \
      --current-version "\$("\$LAUNCHER" --version)" --app-dir "\$APP_DIR" \
      --bin-dir "$BIN_DIR" --config "\$CONFIG_FILE" --service-file "\$SERVICE_FILE"
    ;;
  update)
    shift 2>/dev/null || true
    exec python3 "\$APP_DIR/clipman_server_updater.py" --install "\$@" \
      --current-version "\$("\$LAUNCHER" --version)" --app-dir "\$APP_DIR" \
      --bin-dir "$BIN_DIR" --config "\$CONFIG_FILE" --service-file "\$SERVICE_FILE"
    ;;
  enable-auto-updates)
    if ! has_user_service; then
      echo "Automatic updates require an installed user service." >&2
      exit 2
    fi
    if [ "\$INIT_SYSTEM" = systemd ]; then
      systemctl --user daemon-reload
      systemctl --user enable --now clipman-server-update.timer
    else
      rm -f "\$UPDATE_SERVICE_FILE/down"
      sv up "\$UPDATE_SERVICE_FILE"
    fi
    echo "Automatic Clipman Server updates enabled."
    ;;
  disable-auto-updates)
    if [ "\$INIT_SYSTEM" = systemd ]; then
      systemctl --user disable --now clipman-server-update.timer 2>/dev/null || true
    else
      touch "\$UPDATE_SERVICE_FILE/down"
      sv down "\$UPDATE_SERVICE_FILE" 2>/dev/null || true
    fi
    echo "Automatic Clipman Server updates disabled."
    ;;
  update-status)
    if [ "\$INIT_SYSTEM" = systemd ]; then
      systemctl --user status clipman-server-update.timer --no-pager
    else
      sv status "\$UPDATE_SERVICE_FILE"
    fi
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
echo "For private-CA HTTPS, run:"
echo "  clipmanserver cert"
echo
echo "Run now with:"
echo "  clipmanserver start"

if [ "$INIT_SYSTEM" = systemd ]; then
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
  cat > "$SERVICE_DIR/clipman-server-update.service" <<EOF
[Unit]
Description=Update Clipman Server
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN_DIR/clipmanserver update --yes
EOF
  cat > "$SERVICE_DIR/clipman-server-update.timer" <<EOF
[Unit]
Description=Check daily for Clipman Server updates

[Timer]
OnBootSec=15m
OnUnitActiveSec=1d
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
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
  if systemctl --user daemon-reload >/dev/null 2>&1 && systemctl --user enable --now clipman-server-update.timer >/dev/null 2>&1; then
    echo
    echo "Automatic daily server updates are enabled."
    echo "Disable them with: clipmanserver disable-auto-updates"
  else
    echo
    echo "Automatic updates could not be enabled in this session."
    echo "Enable them later with: clipmanserver enable-auto-updates"
  fi
fi

if [ "$INIT_SYSTEM" = runit ]; then
  mkdir -p "$SERVICE_FILE" "$UPDATE_SERVICE_FILE"
  cat > "$SERVICE_FILE/run" <<EOF
#!/usr/bin/env sh
exec 2>&1
set -e
exec $BIN_DIR/clipman-server
EOF
  chmod 700 "$SERVICE_FILE/run"
  cat > "$UPDATE_SERVICE_FILE/run" <<EOF
#!/usr/bin/env sh
exec 2>&1
set -e
while :; do
  sleep 900
  $BIN_DIR/clipmanserver update --yes || true
  sleep 85500
done
EOF
  chmod 700 "$UPDATE_SERVICE_FILE/run"
  : > "$UPDATE_SERVICE_FILE/down"
  echo
  echo "A turnstile user runit service was written to:"
  echo "  $SERVICE_FILE"
  echo
  echo "Start it with: clipmanserver start"
  echo "Enable daily updates with: clipmanserver enable-auto-updates"
fi

if [ "$TURNSTILE_MISSING" -eq 1 ]; then
  echo
  echo "runit was detected, but turnstile is not installed."
  echo "Clipman Server was installed without a persistent per-user service."
  if command -v xbps-install >/dev/null 2>&1; then
    echo "To add one, run: sudo xbps-install -S turnstile"
    echo "Enable the turnstiled system service, then run this installer again."
  else
    echo "Install and enable turnstile, then run this installer again."
  fi
fi
