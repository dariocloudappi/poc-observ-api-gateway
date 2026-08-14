#!/usr/bin/env bash
# =============================================================================
# generate-local-certs.sh
# -----------------------------------------------------------------------------
# Generates the self signed certificate used by the gateway for LOCAL
# development only. The material is written to tyk/certs/, which is git
# ignored: certificates and private keys must never be committed.
#
# Usage: ./scripts/generate-local-certs.sh [common-name]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CERT_DIR="$PROJECT_DIR/tyk/certs"

CN="${1:-${LOCAL_CERT_CN:-localhost}}"
DAYS="${LOCAL_CERT_DAYS:-90}"

if ! command -v openssl >/dev/null 2>&1; then
  echo "ERROR: openssl is required" >&2
  exit 1
fi

mkdir -p "$CERT_DIR"

if [ -f "$CERT_DIR/cert.pem" ] && [ "${FORCE:-false}" != "true" ]; then
  echo "Certificate already present in $CERT_DIR. Use FORCE=true to regenerate."
  exit 0
fi

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$CERT_DIR/key.pem" \
  -out "$CERT_DIR/cert.pem" \
  -days "$DAYS" \
  -subj "/CN=${CN}" \
  -addext "subjectAltName=DNS:${CN},DNS:localhost,IP:127.0.0.1" \
  >/dev/null 2>&1

chmod 0600 "$CERT_DIR/key.pem"
chmod 0644 "$CERT_DIR/cert.pem"

echo "Generated self signed certificate for CN=${CN}, valid ${DAYS} days:"
echo "  $CERT_DIR/cert.pem"
echo "  $CERT_DIR/key.pem"
echo "Local development only. Do not use for any public endpoint."
