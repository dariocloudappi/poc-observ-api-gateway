#!/usr/bin/env bash
# =============================================================================
# provision_key.sh
# -----------------------------------------------------------------------------
# Creates the Basic Auth keys that consumers present to the gateway.
#
# Every value comes from the environment. If a .env file exists next to this
# script it is loaded first, otherwise the variables are expected to be already
# exported (that is how the pipeline calls it).
#
# Required variables:
#   TYK_SECRET                    gateway admin API secret
#   GATEWAY_BASE_URL              e.g. https://localhost:8443
#   USERNAME_API_USERS  / PASSWORD_API_USERS
#   USERNAME_API_ORDERS / PASSWORD_API_ORDERS
# Optional:
#   TYK_ORG_ID                    default poc-organization
#   GATEWAY_ALLOW_INSECURE_TLS    true only for local self signed certificates
#
# No secret is echoed by this script.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env without exporting through the command line, so values never show up
# in the process list.
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/.env"
  set +a
fi

TYK_ORG_ID="${TYK_ORG_ID:-poc-organization}"
GATEWAY_BASE_URL="${GATEWAY_BASE_URL:-https://localhost:8443}"
GATEWAY_ALLOW_INSECURE_TLS="${GATEWAY_ALLOW_INSECURE_TLS:-false}"

require_var() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "ERROR: required environment variable $name is not set" >&2
    exit 1
  fi
}

require_var TYK_SECRET

CURL_OPTS=(--location --fail --silent --show-error)
if [ "$GATEWAY_ALLOW_INSECURE_TLS" = "true" ]; then
  # Only acceptable against a local self signed certificate.
  echo "WARNING: TLS verification disabled (GATEWAY_ALLOW_INSECURE_TLS=true)"
  CURL_OPTS+=(--insecure)
fi

# api_id : user variable : password variable
APPS=(
  "api-users-001:USERNAME_API_USERS:PASSWORD_API_USERS"
  "api-orders-001:USERNAME_API_ORDERS:PASSWORD_API_ORDERS"
)

for entry in "${APPS[@]}"; do
  IFS=":" read -r API_ID USER_VAR PASS_VAR <<< "$entry"
  USERNAME="${!USER_VAR:-}"
  PASSWORD="${!PASS_VAR:-}"

  if [[ -z "$USERNAME" || -z "$PASSWORD" ]]; then
    echo "Variables $USER_VAR / $PASS_VAR not defined, skipping $API_ID"
    continue
  fi

  echo "Creating key for $API_ID (user: $USERNAME)"

  payload=$(cat <<JSON
{
  "allowance": 1000,
  "rate": 1000,
  "per": 60,
  "expires": -1,
  "quota_max": -1,
  "quota_remaining": -1,
  "quota_renewal_rate": 60,
  "org_id": "${TYK_ORG_ID}",
  "access_rights": {
    "${API_ID}": {
      "api_id": "${API_ID}",
      "api_name": "${API_ID}",
      "versions": ["Default"]
    }
  },
  "basic_auth_data": {
    "password": "${PASSWORD}"
  }
}
JSON
)

  # The admin secret travels in a header, never in the URL or in the logs.
  curl "${CURL_OPTS[@]}" \
    --header "x-tyk-authorization: ${TYK_SECRET}" \
    --header 'Content-Type: application/json' \
    --data "$payload" \
    --output /dev/null \
    "${GATEWAY_BASE_URL}/tyk/keys/${USERNAME}"

  echo "  key for $API_ID provisioned"
done

echo "Done. Consumers authenticate with HTTP Basic Auth using the configured user and password."
