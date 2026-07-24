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

mkdir -p "$DATA_DIR" "$(dirname "$LOG_PATH")"

if [ "${CLIPMAN_SELF_SIGNED_CERT:-}" = "true" ] && [ -z "$CERT_FILE" ] && [ -z "$KEY_FILE" ]; then
  GENERATED_CERT="$DATA_DIR/tls/clipman-server-fullchain.crt"
  GENERATED_KEY="$DATA_DIR/tls/clipman-server.key"
  if [ ! -f "$GENERATED_CERT" ] || [ ! -f "$GENERATED_KEY" ]; then
    set -- /app/clipman_server.py \
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
  echo "Private-CA HTTPS is enabled. Install and trust $DATA_DIR/tls/clipman-server-ca.crt on each client."
fi

set -- /app/clipman_server.py \
  --config "$CONFIG_PATH" \
  --host "$HOST" \
  --port "$PORT" \
  --database "$DATABASE_PATH" \
  --log "$LOG_PATH" \
  --write-connection-info

if [ -n "$ADVERTISE_HOST" ]; then
  set -- "$@" --advertise-host "$ADVERTISE_HOST"
fi

if [ -n "$CERT_FILE" ] && [ -n "$KEY_FILE" ]; then
  set -- "$@" --cert-file "$CERT_FILE" --key-file "$KEY_FILE"
elif [ "${CLIPMAN_IS_BEHIND_REVERSE_PROXY:-}" = "true" ] || [ "${CLIPMAN_ALLOW_INSECURE_REMOTE:-}" = "true" ]; then
  set -- "$@" --allow-insecure-remote
fi

exec python3 "$@"
