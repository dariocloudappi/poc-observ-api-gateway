#!/bin/sh
# =============================================================================
# gateway-entrypoint.sh
# -----------------------------------------------------------------------------
# Renders the Tyk API definitions from the templates in APPS_TEMPLATE_DIR into
# APPS_DIR before starting the gateway. All sensitive values (upstream Basic
# Auth credentials) come from environment variables, so no credential is ever
# stored in the repository or baked into the image.
#
# The script never prints the value of a secret. It only reports which
# variables are missing.
# =============================================================================

set -eu

APPS_TEMPLATE_DIR="${APPS_TEMPLATE_DIR:-/opt/tyk-gateway/apps-templates}"
APPS_DIR="${APPS_DIR:-/opt/tyk-gateway/apps}"

TYK_ORG_ID="${TYK_ORG_ID:-poc-organization}"
TYK_DETAILED_TRACING="${TYK_DETAILED_TRACING:-false}"

log() {
  echo "[gateway-entrypoint] $*"
}

fail() {
  echo "[gateway-entrypoint] ERROR: $*" >&2
  exit 1
}

# Escapes the characters that are special for the sed replacement side.
sed_escape() {
  printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

# Builds an HTTP Basic Auth header value from a user and a password.
# Usage: basic_header <user> <password>
basic_header() {
  printf '%s:%s' "$1" "$2" | base64 | tr -d '\n' | sed -e 's/^/Basic /'
}

require_var() {
  # Usage: require_var <name>
  eval "value=\${$1:-}"
  if [ -z "$value" ]; then
    fail "required environment variable $1 is not set"
  fi
}

# -----------------------------------------------------------------------------
# Validate inputs
# -----------------------------------------------------------------------------

require_var UPSTREAM_USERS_TARGET_URL
require_var UPSTREAM_USERS_BASIC_USER
require_var UPSTREAM_USERS_BASIC_PASSWORD
require_var UPSTREAM_ORDERS_TARGET_URL
require_var UPSTREAM_ORDERS_BASIC_USER
require_var UPSTREAM_ORDERS_BASIC_PASSWORD

if ! command -v base64 >/dev/null 2>&1; then
  fail "base64 is not available in the image, cannot build the upstream auth headers"
fi

# -----------------------------------------------------------------------------
# Render templates
# -----------------------------------------------------------------------------

USERS_AUTH_HEADER="$(basic_header "$UPSTREAM_USERS_BASIC_USER" "$UPSTREAM_USERS_BASIC_PASSWORD")"
ORDERS_AUTH_HEADER="$(basic_header "$UPSTREAM_ORDERS_BASIC_USER" "$UPSTREAM_ORDERS_BASIC_PASSWORD")"

mkdir -p "$APPS_DIR"
rm -f "$APPS_DIR"/*.json 2>/dev/null || true

rendered=0
for template in "$APPS_TEMPLATE_DIR"/*.json.tpl; do
  [ -e "$template" ] || fail "no API definition templates found in $APPS_TEMPLATE_DIR"
  target="$APPS_DIR/$(basename "$template" .tpl)"

  sed \
    -e "s|%%TYK_ORG_ID%%|$(sed_escape "$TYK_ORG_ID")|g" \
    -e "s|%%TYK_DETAILED_TRACING%%|$(sed_escape "$TYK_DETAILED_TRACING")|g" \
    -e "s|%%UPSTREAM_USERS_TARGET_URL%%|$(sed_escape "$UPSTREAM_USERS_TARGET_URL")|g" \
    -e "s|%%UPSTREAM_ORDERS_TARGET_URL%%|$(sed_escape "$UPSTREAM_ORDERS_TARGET_URL")|g" \
    -e "s|%%UPSTREAM_USERS_AUTH_HEADER%%|$(sed_escape "$USERS_AUTH_HEADER")|g" \
    -e "s|%%UPSTREAM_ORDERS_AUTH_HEADER%%|$(sed_escape "$ORDERS_AUTH_HEADER")|g" \
    "$template" > "$target"

  chmod 0640 "$target"

  # Fail fast if any placeholder was left unresolved.
  if grep -q '%%[A-Z_]*%%' "$target"; then
    fail "unresolved placeholder in $(basename "$target")"
  fi

  rendered=$((rendered + 1))
  log "rendered $(basename "$target")"
done

log "rendered $rendered API definition(s) into $APPS_DIR"

# -----------------------------------------------------------------------------
# Hand over to the gateway
# -----------------------------------------------------------------------------

unset UPSTREAM_USERS_BASIC_PASSWORD UPSTREAM_ORDERS_BASIC_PASSWORD
unset USERS_AUTH_HEADER ORDERS_AUTH_HEADER

if [ -x /opt/tyk-gateway/entrypoint.sh ]; then
  exec /opt/tyk-gateway/entrypoint.sh "$@"
fi

exec "$@"
