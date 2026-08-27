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

upsert_key() {
  api_id="$1"
  user="$2"
  pass="$3"

  # access_rights se indexa por api_id, asi que este valor DEBE coincidir con el
  # api_id de la definicion de API. Si no coincide, Tyk autentica al usuario
  # pero responde "Access to this API has been disallowed", que es un sintoma
  # distinto del 401.
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
    "password": "${pass}"
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

while true; do
  for entry in "api-users-001:${USERNAME_API_USERS:-}:${PASSWORD_API_USERS:-}" \
               "api-orders-001:${USERNAME_API_ORDERS:-}:${PASSWORD_API_ORDERS:-}"; do
    api_id=$(echo "$entry" | cut -d: -f1)
    user=$(echo "$entry" | cut -d: -f2)
    pass=$(echo "$entry" | cut -d: -f3)

    if [ -z "$user" ] || [ -z "$pass" ]; then
      continue
    fi

    if upsert_key "$api_id" "$user" "$pass"; then
      log "${api_id} credencial escrita"
    else
      # No se aborta: el gateway puede estar recargando definiciones. El
      # siguiente ciclo lo reintenta.
      log "AVISO no se pudo escribir la credencial de ${api_id}, se reintenta en ${INTERVAL}s"
    fi
  done

  sleep "$INTERVAL"
done
