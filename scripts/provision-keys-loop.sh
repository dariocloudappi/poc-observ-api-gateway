#!/bin/sh
# =============================================================================
# provision-keys-loop.sh
# -----------------------------------------------------------------------------
# Mantiene vivas las credenciales de consumidor del gateway. Corre como
# contenedor sidecar dentro de la misma replica que Tyk.
#
# FUNCION
# -------
# Las credenciales de Basic Auth de Tyk residen unicamente en Redis, que aqui es
# un sidecar sin persistencia. Cada replica nueva, cada cambio de revision y
# cada reprogramacion de la plataforma parte de un Redis vacio, tras lo cual
# todo consumidor obtiene:
#
#   401 {"error": "User not authorised"}
#
# En un Redis recien creado solo permanecen las claves internas de Tyk
# (tyk-liveness-probe, host-checker, version-check).
#
# El aprovisionamiento de la pipeline se ejecuta solo durante un despliegue y no
# cubre los reinicios posteriores. Este bucle arranca con la replica, espera a
# que el gateway responda y reescribe las credenciales.
#
# ESCRITURA INCONDICIONAL
# -----------------------
# Se reescribe siempre en lugar de comprobar y crear si falta, porque la
# comprobacion no es concluyente: tras un FLUSHALL de Redis, Tyk sigue
# autenticando y su API de administracion sigue devolviendo la clave, dado que
# conserva la sesion en una cache en memoria. Una comprobacion previa daria por
# valido un estado en el que Redis esta vacio, y el 401 apareceria al reciclarse
# la cache.
#
# Un POST a /tyk/keys/{nombre} es un upsert, de modo que reescribir es
# idempotente y no depende de ninguna cache. El coste es una escritura por
# ciclo.
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

# Escapa un valor para insertarlo en una cadena JSON.
#
# Interpolar la contrasena directamente en la plantilla JSON corrompe cualquier
# valor que contenga barra invertida: con secuencias como barra-n, barra-t o
# barra-slash el POST responde 200 y la clave queda en Redis, pero el consumidor
# obtiene 401 de forma permanente, porque Tyk almacena el escape ya
# decodificado y deja de coincidir con lo que envia el cliente. Con dos barras
# consecutivas el POST responde 400.
#
# La imagen de curl no incluye jq, de modo que el escapado se hace con sed. El
# orden es relevante: primero las barras invertidas, ya que en orden inverso se
# volverian a escapar las que introduce el segundo patron.
# Detecta espacio en blanco al principio o al final de un valor.
#
# MOTIVO, reproducido contra el gateway: un salto de linea o un espacio final
# en el secret, tipico al pegarlo, se almacena como parte de la contrasena. El
# POST responde 200, la clave queda en Redis y el consumidor recibe 401 con
# este mensaje en el log de Tyk:
#
#   Attempted access with existing user, failed password check.
#   crypto/bcrypt: hashedPassword is not the hash of the given password
#
# Es invisible: el valor parece correcto en todas partes. Se registra el error
# y se omite esa API en lugar de recortarlo en silencio, que dejaria
# almacenada una contrasena distinta de la del secret.
#
# Expansion de parametros POSIX para que funcione en la shell de la imagen de
# curl, que no es bash.
has_edge_space() {
  v="$1"
  t="${v#"${v%%[![:space:]]*}"}"
  t="${t%"${t##*[![:space:]]}"}"
  [ "$t" != "$v" ]
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

upsert_key() {
  api_id="$1"
  user="$2"
  pass="$3"

  pass_json=$(json_escape "$pass")

  # access_rights se indexa por api_id, por lo que este valor debe coincidir con
  # el api_id de la definicion de API. Si no coincide, Tyk autentica al usuario
  # pero responde 403 con "Access to this API has been disallowed".
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

  # Basic Auth no admite dos puntos en las credenciales. Se comprueba aqui
  # porque la clave se crea sin error y el consumidor recibe un 400, no un 401:
  #
  #   "Attempted access with malformed header, values not in basic auth format."
  #
  # La cabecera transporta base64(usuario:contrasena) y se divide por el primer
  # dos puntos, de modo que un dos puntos en el usuario es irrepresentable. Tyk
  # exige exactamente dos partes, lo que descarta tenerlo en la contrasena.
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

  if has_edge_space "$user"; then
    log "ERROR ${api_id} el secret del USUARIO tiene espacio o salto de linea al principio o al final. Vuelve a crearlo limpio."
    return 1
  fi
  if has_edge_space "$pass"; then
    log "ERROR ${api_id} el secret de la CONTRASENA tiene espacio o salto de linea al principio o al final."
    log "      Tyk lo almacenaria como parte de la credencial y el consumidor recibiria 401"
    log "      con \"failed password check\" aunque el valor parezca correcto. Vuelve a crearlo limpio."
    return 1
  fi

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

# Los usuarios de las dos APIs DEBEN ser distintos.
#
# MOTIVO, reproducido contra el gateway: Tyk indexa las claves de basic auth
# como org_id + usuario. Con el mismo usuario, la segunda escritura pisa la
# primera y en Redis queda UNA sola clave, con el access_rights y la contrasena
# de la segunda API. Los dos POST devuelven 200 y nada avisa. La API que se
# escribe primero empieza a devolver 401 con
#   "Attempted access with existing user, failed password check."
#
# Se comprueba una vez, antes del bucle, y el contenedor se queda dormido en
# lugar de salir: un exit haria que Container Apps lo reiniciase sin parar y el
# error se perderia entre reinicios.
if [ -n "${USERNAME_API_USERS:-}" ] && [ "${USERNAME_API_USERS:-}" = "${USERNAME_API_ORDERS:-}" ]; then
  log "ERROR USERNAME_API_USERS y USERNAME_API_ORDERS son IGUALES."
  log "      Tyk indexa las claves como org_id + usuario, asi que una pisaria a la"
  log "      otra y una de las dos APIs devolveria 401 con \"failed password check\"."
  log "      Usa un usuario distinto para cada API. No se aprovisiona nada."
  while true; do sleep 3600; done
fi

while true; do
  # El "|| true" es imprescindible: con set -e, un process_api que devuelve 1
  # (credencial invalida) abortaria el script y la SEGUNDA API se quedaria sin
  # credencial por un problema de la primera. Cada API debe fallar por su
  # cuenta.
  process_api "api-users-001"  "${USERNAME_API_USERS:-}"  "${PASSWORD_API_USERS:-}"  || true
  process_api "api-orders-001" "${USERNAME_API_ORDERS:-}" "${PASSWORD_API_ORDERS:-}" || true

  sleep "$INTERVAL"
done
