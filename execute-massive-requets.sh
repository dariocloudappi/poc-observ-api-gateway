#!/usr/bin/env bash
# =============================================================================
# execute-massive-requets.sh
# -----------------------------------------------------------------------------
# Generates traffic against the gateway so there is something to look at in
# New Relic. Credentials come from .env, never from this file.
#
# Usage:
#   ./execute-massive-requets.sh [count] [users|orders]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/.env"
  set +a
fi

COUNT="${1:-20}"
TARGET="${2:-users}"

GATEWAY_BASE_URL="${GATEWAY_BASE_URL:-https://localhost:8443}"

case "$TARGET" in
  users)
    URL="${GATEWAY_BASE_URL}/api-users/v1${USERS_HEALTH_PATH:-/}"
    USER="${USERNAME_API_USERS:-}"
    PASS="${PASSWORD_API_USERS:-}"
    ;;
  orders)
    URL="${GATEWAY_BASE_URL}/api-orders/v1${ORDERS_HEALTH_PATH:-/}"
    USER="${USERNAME_API_ORDERS:-}"
    PASS="${PASSWORD_API_ORDERS:-}"
    ;;
  *)
    echo "ERROR: unknown target '$TARGET'. Use users or orders." >&2
    exit 1
    ;;
esac

if [ -z "$USER" ] || [ -z "$PASS" ]; then
  echo "ERROR: consumer credentials for '$TARGET' are not set in the environment" >&2
  exit 1
fi

CURL_OPTS=(--silent --show-error)
if [ "${GATEWAY_ALLOW_INSECURE_TLS:-false}" = "true" ]; then
  CURL_OPTS+=(--insecure)
fi

echo "Sending $COUNT requests to $URL"

for i in $(seq 1 "$COUNT"); do
  (
    START_TIME=$(date +"%Y-%m-%d %H:%M:%S")

    # --user keeps the credentials out of the printed output.
    RESPONSE=$(curl "${CURL_OPTS[@]}" \
      --user "${USER}:${PASS}" \
      -w "\nHTTP_CODE:%{http_code}\nTIME_TOTAL:%{time_total}" \
      "$URL")

    HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
    TIME_TOTAL=$(echo "$RESPONSE" | grep "TIME_TOTAL:" | cut -d: -f2)

    echo "[$START_TIME] request $i -> HTTP $HTTP_CODE in ${TIME_TOTAL}s"
  ) &
done

wait
echo "$COUNT requests sent to $URL"
