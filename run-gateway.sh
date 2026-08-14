#!/usr/bin/env bash
# =============================================================================
# run-gateway.sh
# -----------------------------------------------------------------------------
# Local bring up: certificates, stack, readiness wait and key provisioning.
# Reads .env, which must exist and must not be committed.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f .env ]; then
  echo "ERROR: .env not found. Copy .env.example to .env and fill in the values." >&2
  exit 1
fi

# Load .env into the environment without exposing values in the process list.
set -a
# shellcheck disable=SC1091
. ./.env
set +a

GATEWAY_BASE_URL="${GATEWAY_BASE_URL:-https://localhost:8443}"
TYK_HTTP_USE_SSL="${TYK_HTTP_USE_SSL:-true}"

# Certificates are only needed when the gateway terminates TLS itself.
if [ "$TYK_HTTP_USE_SSL" = "true" ]; then
  ./scripts/generate-local-certs.sh "${LOCAL_CERT_CN:-localhost}"
fi

docker compose down -v
docker compose build
docker compose up -d

echo "Waiting for the gateway to become ready at ${GATEWAY_BASE_URL}/hello ..."

curl_ready_opts=(--silent --fail)
if [ "${GATEWAY_ALLOW_INSECURE_TLS:-false}" = "true" ]; then
  curl_ready_opts+=(--insecure)
fi

attempts=0
until curl "${curl_ready_opts[@]}" "${GATEWAY_BASE_URL}/hello" | grep -q "pass"; do
  attempts=$((attempts + 1))
  if [ "$attempts" -ge 40 ]; then
    echo "ERROR: gateway did not become ready. Check: docker compose logs tyk-gateway" >&2
    exit 1
  fi
  echo "  gateway not ready, retrying in 3s ..."
  sleep 3
done

echo "Gateway is ready, provisioning keys ..."
./provision_key.sh

echo
echo "Stack up. Endpoints:"
echo "  Gateway     ${GATEWAY_BASE_URL}"
echo "  Users API   ${GATEWAY_BASE_URL}/api-users/v1"
echo "  Orders API  ${GATEWAY_BASE_URL}/api-orders/v1"
echo "  Collector   http://127.0.0.1:13133 (health), http://127.0.0.1:8888/metrics"
echo "  Pump        docker compose logs tyk-pump"
