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

# Detecta espacio en blanco al principio o al final de un valor.
#
# MOTIVO, reproducido contra el gateway: un salto de linea o un espacio final
# en el secret, tipico al pegarlo, se almacena como parte de la contrasena.
# El aprovisionamiento responde 200, la clave queda en Redis y el consumidor
# recibe 401 con este mensaje en el log de Tyk:
#
#   Attempted access with existing user, failed password check.
#   crypto/bcrypt: hashedPassword is not the hash of the given password
#
# Es invisible: el valor "parece" correcto en todas partes. Por eso se detecta
# y se ABORTA en lugar de recortarlo en silencio, que dejaria almacenada una
# contrasena distinta de la del secret y volveria a fallar en cuanto alguien
# usara el valor original.
has_edge_space() {
  local v t
  v="$1"
  t="${v#"${v%%[![:space:]]*}"}"
  t="${t%"${t##*[![:space:]]}"}"
  [ "$t" != "$v" ]
}

# jq construye el payload JSON. Sin el, la unica alternativa es interpolar la
# contrasena en una plantilla, que es justo el fallo que este script evita.
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq no esta disponible y es necesario para construir el payload" >&2
  echo "sin corromper contrasenas que contengan barras invertidas." >&2
  exit 1
fi

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

  # Se comprueba ANTES de crear la clave: si se crea con la contrasena sucia,
  # queda una credencial que nadie puede usar.
  for pair in "USERNAME:$USER_VAR" "PASSWORD:$PASS_VAR"; do
    which="${pair%%:*}"
    varname="${pair##*:}"
    case "$which" in
      USERNAME) val="$USERNAME" ;;
      PASSWORD) val="$PASSWORD" ;;
    esac
    if has_edge_space "$val"; then
      echo "ERROR: el secret ${varname} tiene espacio en blanco al principio o al final." >&2
      echo "Normalmente es un salto de linea al pegarlo. Tyk lo almacenaria como" >&2
      echo "parte de la credencial y el consumidor recibiria 401 con el mensaje" >&2
      echo "\"failed password check\" aunque el valor parezca correcto." >&2
      echo "Vuelve a crear el secret sin el salto de linea final." >&2
      exit 1
    fi
  done

  # HUELLA de la credencial, para poder comparar lo que se ESCRIBE aqui con lo
  # que luego se ENVIA al verificar, sin revelar el valor.
  #
  # Existe porque el sintoma era irreproducible por deduccion: la pipeline crea
  # la clave y la comprueba con el MISMO secret, asi que deberia funcionar
  # siempre. Cuando no funciona, significa que algo transforma el valor en uno
  # de los dos caminos. Comparando longitud y hash se ve de inmediato si el
  # valor escrito y el enviado son el mismo, y cuando dejan de serlo.
  fingerprint() {
    printf '%s' "$1" | sha256sum | cut -c1-12
  }
  echo "Creating key for $API_ID (user: $USERNAME)"
  echo "  huella usuario:    len=${#USERNAME} sha=$(fingerprint "$USERNAME")"
  echo "  huella contrasena: len=${#PASSWORD} sha=$(fingerprint "$PASSWORD")"

  # El payload se construye con jq y NO interpolando en una plantilla.
  #
  # MOTIVO, medido contra el gateway: al meter la contrasena directamente
  # dentro de una cadena JSON, cualquier barra invertida que forme un escape
  # JSON valido cambia el valor almacenado SIN dar error. Con una contrasena
  # que contenga barra-n, barra-t o barra-slash, el aprovisionamiento
  # respondia 200, la clave quedaba en Redis y el consumidor recibia 401 para
  # siempre: Tyk habia guardado el escape ya decodificado, distinto de lo que
  # envia el cliente. Con dos barras seguidas la peticion fallaba con 400.
  #
  # jq escapa el valor segun JSON, asi que la contrasena llega intacta sea
  # cual sea su contenido.
  payload=$(jq -n \
    --arg org "$TYK_ORG_ID" \
    --arg api "$API_ID" \
    --arg pass "$PASSWORD" \
    '{
      allowance: 1000,
      rate: 1000,
      per: 60,
      expires: -1,
      quota_max: -1,
      quota_remaining: -1,
      quota_renewal_rate: 60,
      org_id: $org,
      access_rights: {
        ($api): { api_id: $api, api_name: $api, versions: ["Default"] }
      },
      basic_auth_data: { password: $pass }
    }')

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
