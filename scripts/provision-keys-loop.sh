#!/bin/sh
# =============================================================================
# provision-keys-loop.sh
# -----------------------------------------------------------------------------
# Mantiene vivas las credenciales de consumidor del gateway. Corre como
# contenedor sidecar dentro de la misma replica que Tyk.
#
# POR QUE EXISTE
# --------------
# Las credenciales de Basic Auth de Tyk viven SOLO en Redis, y aqui Redis es un
# sidecar sin persistencia. Cada replica nueva, cada cambio de revision y cada
# reprogramacion de la plataforma arranca con un Redis vacio, y a partir de ese
# momento todo consumidor recibe:
#
#   401 {"error": "User not authorised"}
#
# Reproducido en local: con un Redis recien creado las unicas claves que quedan
# son las internas de Tyk (tyk-liveness-probe, host-checker, version-check) y
# ninguna de usuario.
#
# El aprovisionamiento de la pipeline solo corre durante un despliegue, asi que
# no cubre los reinicios posteriores. Este bucle si: arranca con la replica,
# espera a que el gateway responda y reescribe las credenciales.
#
# POR QUE UPSERT INCONDICIONAL Y NO "comprobar y crear si falta"
# --------------------------------------------------------------
# Porque comprobar no es fiable. Medido en local: despues de un FLUSHALL de
# Redis, Tyk seguia autenticando y su API de administracion seguia devolviendo
# la clave, porque mantiene la sesion en una cache en memoria. Un
# check-then-create se habria creido que todo estaba bien mientras Redis estaba
# vacio, y al reciclarse la cache habria empezado el 401.
#
# Un POST a /tyk/keys/{nombre} es un upsert, asi que reescribir siempre es
# idempotente y no depende de ninguna cache. El coste es una escritura por
# ciclo, irrelevante a este intervalo.
#
# Variables:
#   TYK_SECRET                   secreto de la API de administracion (obligatorio)
#   TYK_ORG_ID                   default poc-organization
#   GATEWAY_INTERNAL_URL         default http://localhost:8080
#   PROVISION_CHECK_INTERVAL     segundos entre ciclos, default 300
#   USERNAME_API_USERS  / PASSWORD_API_USERS
#   USERNAME_API_ORDERS / PASSWORD_API_ORDERS
#
# Ningun secreto se imprime.
# =============================================================================

set -eu

GW="${GATEWAY_INTERNAL_URL:-http://localhost:8080}"
ORG="${TYK_ORG_ID:-poc-organization}"
INTERVAL="${PROVISION_CHECK_INTERVAL:-300}"

if [ -z "${TYK_SECRET:-}" ]; then
  echo "provisioner: ERROR TYK_SECRET no esta definido" >&2
  exit 1
fi

log() { echo "provisioner: $*"; }

# El gateway tarda en cargar las definiciones de API y conectar con Redis. Sin
# esta espera el primer POST fallaria y el contenedor entraria en bucle de
# reinicio.
wait_for_gateway() {
  i=0
  while [ "$i" -lt 90 ]; do
    if curl -sf -o /dev/null --max-time 5 "${GW}/hello"; then
      return 0
    fi
    i=$((i + 1))
    sleep 2
  done
  return 1
}

# Escapa un valor para poder meterlo dentro de una cadena JSON.
#
# MOTIVO, medido contra el gateway: interpolar la contrasena directamente en la
# plantilla JSON corrompe en silencio cualquier valor que lleve barra
# invertida. Con una contrasena que contenga barra-n, barra-t o barra-slash el
# POST respondia 200, la clave quedaba en Redis y el consumidor recibia 401
# para siempre, porque Tyk almacenaba el escape ya decodificado y eso no
# coincide con lo que envia el cliente. Con dos barras seguidas el POST fallaba
# con 400.
#
# Aqui no se puede usar jq: la imagen de curl no lo trae. Se escapa con sed y
# el ORDEN IMPORTA: primero las barras invertidas, porque si se hiciera al
# reves se volverian a escapar las que introduce el segundo patron.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

upsert_key() {
  api_id="$1"
  user="$2"
  pass="$3"

  pass_json=$(json_escape "$pass")

  # access_rights se indexa por api_id, asi que este valor DEBE coincidir con el
  # api_id de la definicion de API. Si no coincide, Tyk autentica al usuario
  # pero responde "Access to this API has been disallowed" con un 403, que es
  # un sintoma distinto del 401.
  payload=$(cat <<JSON
{
  "allowance": 1000,
  "rate": 1000,
  "per": 60,
  "expires": -1,
  "quota_max": -1,
  "quota_remaining": -1,
  "quota_renewal_rate": 60,
  "org_id": "${ORG}",
  "access_rights": {
    "${api_id}": {
      "api_id": "${api_id}",
      "api_name": "${api_id}",
      "versions": ["Default"]
    }
  },
  "basic_auth_data": {
    "password": "${pass_json}"
  }
}
JSON
)

  if curl -sf -o /dev/null --max-time 10 -X POST \
      -H "x-tyk-authorization: ${TYK_SECRET}" \
      -H 'Content-Type: application/json' \
      --data "$payload" \
      "${GW}/tyk/keys/${user}"; then
    return 0
  fi
  return 1
}

if ! wait_for_gateway; then
  log "ERROR el gateway no respondio en /hello tras 180s"
  exit 1
fi
log "gateway disponible, empiezo a mantener las credenciales"

# Si no hay ninguna credencial configurada no hay nada que mantener. Se queda
# dormido en lugar de salir: un exit haria que Container Apps reiniciase el
# contenedor en bucle.
if [ -z "${USERNAME_API_USERS:-}" ] && [ -z "${USERNAME_API_ORDERS:-}" ]; then
  log "AVISO no hay credenciales configuradas, no hay nada que aprovisionar"
  while true; do sleep 3600; done
fi

# Procesa una API. Los valores se pasan como ARGUMENTOS SEPARADOS.
#
# La version anterior los empaquetaba en una cadena "api:usuario:contrasena" y
# los separaba con cut -d: -f3. Era un bug: cualquier contrasena que contuviese
# dos puntos quedaba TRUNCADA en el primero. Con "Pa:ss" se guardaba "Pa", el
# aprovisionamiento respondia 200 y el consumidor recibia 401 para siempre.
# Y afectaba solo a la API cuya contrasena tuviera dos puntos, lo que hacia
# parecer que las dos APIs se comportaban de forma distinta.
#
# Con argumentos separados no hay separador que colisione con el contenido.
process_api() {
  api_id="$1"
  user="$2"
  pass="$3"

  if [ -z "$user" ] || [ -z "$pass" ]; then
    log "${api_id} sin credenciales configuradas, se omite"
    return 0
  fi

  # Los dos puntos son IMPOSIBLES en Basic Auth, y hay que detectarlo aqui
  # porque el sintoma es enganoso: la clave se crea sin error y el consumidor
  # recibe un 400, no un 401.
  #
  # Medido contra el gateway: con dos puntos en la contrasena Tyk registra
  #   "Attempted access with malformed header, values not in basic auth format."
  # y responde 400. El motivo es la propia especificacion: la cabecera lleva
  # base64(usuario:contrasena) y se parte por el PRIMER dos puntos, asi que un
  # dos puntos en el usuario es irrepresentable y Tyk exige exactamente dos
  # partes, lo que descarta tenerlo tambien en la contrasena.
  case "$user" in
    *:*)
      log "ERROR ${api_id} el USUARIO contiene ':' y Basic Auth no lo admite. Cambia el secret."
      return 1
      ;;
  esac
  case "$pass" in
    *:*)
      log "ERROR ${api_id} la CONTRASENA contiene ':' y Tyk la rechaza con 400. Cambia el secret."
      return 1
      ;;
  esac

  # El identificador con el que Tyk indexa la clave. Se registra para poder
  # comprobarla contra la API de administracion:
  #   GET /tyk/keys/<key_id>  ->  200 existe, 404 no existe
  # No es un secreto: es el usuario con el org delante.
  log "${api_id} key_id=${ORG}${user}"

  if upsert_key "$api_id" "$user" "$pass"; then
    log "${api_id} credencial escrita"
  else
    # No se aborta: el gateway puede estar recargando definiciones. El
    # siguiente ciclo lo reintenta.
    log "AVISO no se pudo escribir la credencial de ${api_id}, se reintenta en ${INTERVAL}s"
  fi
}

while true; do
  process_api "api-users-001"  "${USERNAME_API_USERS:-}"  "${PASSWORD_API_USERS:-}"
  process_api "api-orders-001" "${USERNAME_API_ORDERS:-}" "${PASSWORD_API_ORDERS:-}"

  sleep "$INTERVAL"
done
