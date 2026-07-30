#!/usr/bin/env sh
set -eu

DATA_DIR="${CLIPMAN_DATA_DIR:-/data}"
CONFIG_PATH="${CLIPMAN_CONFIG:-$DATA_DIR/clipman-server-settings.json}"
DATABASE_PATH="${CLIPMAN_DATABASE:-$DATA_DIR/clipman-history.clipdb}"
LOG_PATH="${CLIPMAN_LOG:-$DATA_DIR/logs/clipman-server.log}"
HOST="${CLIPMAN_HOST:-0.0.0.0}"
PORT="${CLIPMAN_PORT:-8080}"
ADVERTISE_HOST="${CLIPMAN_ADVERTISE_HOST:-}"
CERT_FILE="${CLIPMAN_CERT_FILE:-}"
KEY_FILE="${CLIPMAN_KEY_FILE:-}"
SERVER_SCRIPT="${CLIPMAN_SERVER_SCRIPT:-/app/clipman_server.py}"

mkdir -p "$DATA_DIR" "$(dirname "$LOG_PATH")"

if [ "${CLIPMAN_SELF_SIGNED_CERT:-}" = "true" ] && [ -z "$CERT_FILE" ] && [ -z "$KEY_FILE" ]; then
  GENERATED_CERT="$DATA_DIR/tls/clipman-server-fullchain.crt"
  GENERATED_KEY="$DATA_DIR/tls/clipman-server.key"
  if [ ! -f "$GENERATED_CERT" ] || [ ! -f "$GENERATED_KEY" ]; then
    set -- "$SERVER_SCRIPT" \
      --config "$CONFIG_PATH" \
      --host "$HOST" \
      --port "$PORT" \
      --database "$DATABASE_PATH" \
      --log "$LOG_PATH" \
      --create-tls-certificate
    if [ -n "$ADVERTISE_HOST" ]; then
      set -- "$@" --advertise-host "$ADVERTISE_HOST"
    fi
    for name in ${CLIPMAN_CERT_HOSTS:-}; do
      set -- "$@" --cert-host "$name"
    done
    for address in ${CLIPMAN_CERT_IPS:-}; do
      set -- "$@" --cert-ip "$address"
    done
    python3 "$@"
  fi
  CERT_FILE="$GENERATED_CERT"
  KEY_FILE="$GENERATED_KEY"
  echo "Private-CA HTTPS is enabled. Import $DATA_DIR/clipman-server-connection.clpconf in current Clipman clients; it includes the public authority."
  echo "The public CA at $DATA_DIR/tls/clipman-server-ca.crt is retained for older clients and manual recovery."
fi

set -- "$SERVER_SCRIPT" \
  --config "$CONFIG_PATH" \
  --host "$HOST" \
  --port "$PORT" \
  --database "$DATABASE_PATH" \
  --log "$LOG_PATH"

if [ -n "$ADVERTISE_HOST" ]; then
  set -- "$@" --advertise-host "$ADVERTISE_HOST"
fi

if [ -n "$CERT_FILE" ] && [ -n "$KEY_FILE" ]; then
  set -- "$@" --cert-file "$CERT_FILE" --key-file "$KEY_FILE"
elif [ "${CLIPMAN_IS_BEHIND_REVERSE_PROXY:-}" = "true" ] || [ "${CLIPMAN_ALLOW_INSECURE_REMOTE:-}" = "true" ]; then
  set -- "$@" --allow-insecure-remote
else
  case "$HOST" in
    127.0.0.1|localhost|::1) ;;
    *)
      echo "Clipman Server will not expose plain HTTP from this container without an explicit trusted transport." >&2
      echo "Use CLIPMAN_IS_BEHIND_REVERSE_PROXY=true behind an HTTPS reverse proxy, configure direct TLS, or use CLIPMAN_ALLOW_INSECURE_REMOTE=true only on a trusted LAN or VPN." >&2
      exit 2
      ;;
  esac
fi

python3 "$@" --write-connection-info >/dev/null
exec python3 "$@"
