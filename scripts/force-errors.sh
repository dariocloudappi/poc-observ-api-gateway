#!/usr/bin/env bash
# =============================================================================
# force-errors.sh
# -----------------------------------------------------------------------------
# Provoca errores a demanda contra el endpoint /force-errors de los dos
# microservicios, ATRAVESANDO EL GATEWAY, para tener material real con el que
# probar alertas y paneles en New Relic.
#
# Por cada API y por cada codigo de la lista lanza N peticiones EN PARALELO y
# comprueba que la respuesta es la que se pidio.
#
#   2 APIs x 9 codigos x 20 peticiones = 360 peticiones
#
# POR QUE NO BASTA CON MIRAR EL CODIGO DE RESPUESTA
# -------------------------------------------------
# Si pides un 401 y recibes un 401, no sabes si lo genero el microservicio o si
# Tyk te rechazo por credenciales malas: los dos son 401. Lo mismo con el 403,
# que es lo que devuelve Tyk cuando la clave no tiene acceso a la API, y con el
# 504, que tambien es lo que devuelve Tyk cuando el upstream no contesta.
#
# Un script que solo comparase el codigo daria POR BUENO justo el caso en el que
# la peticion nunca llego al microservicio. Por eso cada respuesta se clasifica
# ademas por el cuerpo: el error provocado lleva la marca "forced"
# (FORCED_ERROR en users, "Forced Error" en orders) y el rechazo del gateway no.
#
# CREDENCIALES
# ------------
# Nunca van en este fichero. Se leen del entorno o de un .env, con los mismos
# nombres que usa la pipeline:
#
#   GATEWAY_BASE_URL
#   USERNAME_API_USERS  / PASSWORD_API_USERS
#   USERNAME_API_ORDERS / PASSWORD_API_ORDERS
#
# Con --from-azure se sacan de los secretos del container app.
#
# USO
#   ./scripts/force-errors.sh                    las dos APIs, los 9 codigos
#   ./scripts/force-errors.sh --api users        solo una API
#   ./scripts/force-errors.sh --status 503       solo un codigo
#   ./scripts/force-errors.sh --status 500,503   varios
#   ./scripts/force-errors.sh --requests 50      otra cantidad en paralelo
#   ./scripts/force-errors.sh --method GET       atajo por query param
#   ./scripts/force-errors.sh --from-azure       credenciales del container app
#   ./scripts/force-errors.sh --yes              sin confirmacion, para CI
#
# Sale con 0 si todas las respuestas fueron las pedidas, con 1 si alguna no.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# .env, primero el del repo y luego el de scripts/, para no obligar a moverlo
for env_file in "$REPO_DIR/.env" "$SCRIPT_DIR/.env"; do
  if [ -f "$env_file" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a
  fi
done

# -----------------------------------------------------------------------------
# Valores por defecto
# -----------------------------------------------------------------------------

# Ascendente, y los 5xx al final a proposito: si algo va mal se ve con los 4xx,
# que son inofensivos, antes de empezar a generar errores de servidor.
DEFAULT_STATUSES="400,401,403,405,409,415,500,503,504"

REQUESTS="${REQUESTS:-20}"
METHOD="${METHOD:-POST}"
APIS="users orders"
STATUSES="$DEFAULT_STATUSES"
FROM_AZURE=false
ASSUME_YES=false

usage() {
  sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,\} \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --api)        APIS="${2//,/ }"; shift 2 ;;
    --status)     STATUSES="$2"; shift 2 ;;
    --requests)   REQUESTS="$2"; shift 2 ;;
    --method)     METHOD="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"; shift 2 ;;
    --from-azure) FROM_AZURE=true; shift ;;
    --yes|-y)     ASSUME_YES=true; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "ERROR: opcion desconocida '$1'. Usa --help." >&2; exit 2 ;;
  esac
done

case "$METHOD" in
  POST|GET) ;;
  *) echo "ERROR: --method admite POST o GET" >&2; exit 2 ;;
esac

if ! printf '%s' "$REQUESTS" | grep -qE '^[0-9]+$' || [ "$REQUESTS" -lt 1 ]; then
  echo "ERROR: --requests debe ser un entero positivo" >&2
  exit 2
fi

for api in $APIS; do
  case "$api" in
    users|orders) ;;
    *) echo "ERROR: --api admite users u orders, no '$api'" >&2; exit 2 ;;
  esac
done

STATUS_LIST="${STATUSES//,/ }"
for st in $STATUS_LIST; do
  if ! printf '%s' "$st" | grep -qE '^[0-9]{3}$' || [ "$st" -lt 400 ] || [ "$st" -gt 599 ]; then
    echo "ERROR: '$st' no es valido. El endpoint solo acepta 400-599." >&2
    exit 2
  fi
done

GATEWAY_BASE_URL="${GATEWAY_BASE_URL:-}"
if [ -z "$GATEWAY_BASE_URL" ]; then
  echo "ERROR: falta GATEWAY_BASE_URL" >&2
  echo "       Por ejemplo https://ca-tykpoc-gw.<sufijo>.azurecontainerapps.io" >&2
  exit 2
fi
GATEWAY_BASE_URL="${GATEWAY_BASE_URL%/}"

# -----------------------------------------------------------------------------
# Credenciales
# -----------------------------------------------------------------------------

if [ "$FROM_AZURE" = true ]; then
  : "${AZ_RESOURCE_GROUP:?falta AZ_RESOURCE_GROUP para --from-azure}"
  : "${AZ_CONTAINERAPP:?falta AZ_CONTAINERAPP para --from-azure}"
  command -v az >/dev/null 2>&1 || {
    echo "ERROR: --from-azure necesita la CLI de az en el PATH" >&2
    exit 2
  }

  az_secret() {
    az containerapp secret show \
      --resource-group "$AZ_RESOURCE_GROUP" \
      --name "$AZ_CONTAINERAPP" \
      --secret-name "$1" \
      --query value -o tsv 2>/dev/null || true
  }

  echo "Leyendo credenciales de los secretos de $AZ_CONTAINERAPP..."
  USERNAME_API_USERS="$(az_secret consumer-user-api-users)"
  PASSWORD_API_USERS="$(az_secret consumer-password-api-users)"
  USERNAME_API_ORDERS="$(az_secret consumer-user-api-orders)"
  PASSWORD_API_ORDERS="$(az_secret consumer-password-api-orders)"
fi

# Huella, para poder comparar credenciales sin escribirlas en ningun log.
fingerprint() {
  local v="$1"
  if [ -z "$v" ]; then
    echo "VACIA"
    return
  fi
  printf '%s (%s car.)' "$(printf '%s' "$v" | sha256sum | cut -c1-12)" "${#v}"
}

user_for() {
  case "$1" in
    users)  printf '%s' "${USERNAME_API_USERS:-}" ;;
    orders) printf '%s' "${USERNAME_API_ORDERS:-}" ;;
  esac
}

pass_for() {
  case "$1" in
    users)  printf '%s' "${PASSWORD_API_USERS:-}" ;;
    orders) printf '%s' "${PASSWORD_API_ORDERS:-}" ;;
  esac
}

for api in $APIS; do
  if [ -z "$(user_for "$api")" ] || [ -z "$(pass_for "$api")" ]; then
    UP="$(printf '%s' "$api" | tr '[:lower:]' '[:upper:]')"
    echo "ERROR: faltan las credenciales de api-$api." >&2
    echo "       Define USERNAME_API_$UP y PASSWORD_API_$UP," >&2
    echo "       o usa --from-azure con AZ_RESOURCE_GROUP y AZ_CONTAINERAPP." >&2
    exit 2
  fi
done

# El mismo usuario en las dos APIs fue la causa del 401 que nos costo horas: Tyk
# indexa las claves por org_id + username, asi que la segunda sobrescribe a la
# primera y una de las dos APIs deja de autenticar.
if [ "${USERNAME_API_USERS:-}" = "${USERNAME_API_ORDERS:-}" ]; then
  echo "AVISO: las dos APIs usan el MISMO username. Tyk indexa las claves por" >&2
  echo "       org_id + username, asi que una sobrescribe a la otra y una de las" >&2
  echo "       dos APIs devolvera 401 sin que sea culpa de este script." >&2
fi

CURL_OPTS=(--silent --show-error --max-time "${CURL_MAX_TIME:-30}")
if [ "${GATEWAY_ALLOW_INSECURE_TLS:-false}" = "true" ]; then
  CURL_OPTS+=(--insecure)
fi

# -----------------------------------------------------------------------------
# Confirmacion
# -----------------------------------------------------------------------------

N_STATUSES=0
N_5XX=0
for st in $STATUS_LIST; do
  N_STATUSES=$((N_STATUSES + 1))
  [ "$st" -ge 500 ] && N_5XX=$((N_5XX + 1))
done
N_APIS=0
for api in $APIS; do
  N_APIS=$((N_APIS + 1))
done
TOTAL=$((N_APIS * N_STATUSES * REQUESTS))

echo "============================================================"
echo " Generacion de errores contra el gateway"
echo "============================================================"
echo " Gateway     : $GATEWAY_BASE_URL"
echo " APIs        : $APIS"
echo " Codigos     : $STATUS_LIST"
echo " Peticiones  : $REQUESTS en paralelo por codigo y API"
echo " Metodo      : $METHOD"
echo " TOTAL       : $TOTAL peticiones"
for api in $APIS; do
  echo " api-$api"
  echo "   usuario   : $(fingerprint "$(user_for "$api")")"
  echo "   clave     : $(fingerprint "$(pass_for "$api")")"
done
echo "============================================================"

if [ "$N_5XX" -gt 0 ] && [ "$ASSUME_YES" != true ]; then
  echo
  echo "OJO: se van a generar $((N_APIS * N_5XX * REQUESTS)) errores 5xx REALES contra un entorno"
  echo "     desplegado. Si hay alertas configuradas, se van a disparar."
  echo
  echo "     El ruido se puede excluir despues, porque cada error provocado lleva"
  echo "     error.forced = true:"
  echo "       WHERE error.code IS NOT NULL AND error.forced IS NULL"
  echo
  if [ -t 0 ]; then
    printf "     Continuar? [s/N] "
    read -r answer
    case "$answer" in
      s|S|si|SI|y|Y|yes|YES) ;;
      *) echo "     Cancelado."; exit 0 ;;
    esac
  else
    echo "ERROR: no hay terminal interactiva. Pasa --yes si de verdad quieres lanzarlo." >&2
    exit 2
  fi
fi

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# -----------------------------------------------------------------------------
# Una peticion
# -----------------------------------------------------------------------------
# Escribe una linea "codigo|segundos|forced|rc" en un fichero. NUNCA falla: si
# curl se cae, un set -e tumbaria el script entero desde un subshell en segundo
# plano y perderiamos el resto de la tanda.
do_request() {
  local api="$1" status="$2" idx="$3" user="$4" pass="$5"
  local url="${GATEWAY_BASE_URL}/api-${api}/v1/force-errors"
  local body="$TMP/body.$api.$status.$idx"
  local out="$TMP/res.$api.$status.$idx"
  local metrics code time rc=0 forced=no

  if [ "$METHOD" = "POST" ]; then
    metrics=$(curl "${CURL_OPTS[@]}" \
      -o "$body" -w '%{http_code}|%{time_total}' \
      --user "${user}:${pass}" \
      -X POST -H 'Content-Type: application/json' \
      -d "{\"status\": ${status}, \"message\": \"forzado por force-errors.sh\"}" \
      "$url" 2>/dev/null) || rc=$?
  else
    metrics=$(curl "${CURL_OPTS[@]}" \
      -o "$body" -w '%{http_code}|%{time_total}' \
      --user "${user}:${pass}" \
      "${url}?status=${status}&message=forzado%20por%20force-errors.sh" 2>/dev/null) || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    # 000 = no hubo respuesta. rc 28 es timeout, rc 7 conexion rechazada.
    echo "000|0|no|$rc" > "$out"
    return 0
  fi

  code="${metrics%%|*}"
  time="${metrics##*|}"

  # La marca que distingue el error del microservicio del rechazo del gateway.
  if [ -s "$body" ] && grep -qi 'forced' "$body" 2>/dev/null; then
    forced=yes
  fi

  echo "${code}|${time}|${forced}|0" > "$out"
  return 0
}

# -----------------------------------------------------------------------------
# Comprobacion previa
# -----------------------------------------------------------------------------
# Un 400 provocado, que es inofensivo, antes de lanzar cientos de peticiones. Si
# las credenciales estan mal o el endpoint no esta desplegado, se sabe aqui y no
# despues de haber generado 360 errores inutiles.
preflight() {
  local api="$1" user pass code forced
  user="$(user_for "$api")"
  pass="$(pass_for "$api")"

  do_request "$api" 400 preflight "$user" "$pass"
  IFS='|' read -r code _ forced _ < "$TMP/res.$api.400.preflight"

  if [ "$code" = "400" ] && [ "$forced" = "yes" ]; then
    echo "  api-$api: OK, /force-errors responde y las credenciales valen"
    return 0
  fi

  echo "  api-$api: FALLA" >&2
  case "$code" in
    000)
      echo "    Sin respuesta. Revisa GATEWAY_BASE_URL, la red y el TLS." >&2
      echo "    Si el certificado es autofirmado: GATEWAY_ALLOW_INSECURE_TLS=true" >&2
      ;;
    401)
      echo "    401 SIN marca 'forced': el rechazo es del GATEWAY, no del micro." >&2
      echo "    Las credenciales de api-$api no son validas en Tyk." >&2
      echo "    usuario $(fingerprint "$user")" >&2
      echo "    clave   $(fingerprint "$pass")" >&2
      ;;
    403)
      echo "    403 SIN marca 'forced': la clave existe pero NO tiene acceso a" >&2
      echo "    api-$api (access_rights). Es del provisionado, no de este script." >&2
      ;;
    404)
      echo "    404: /force-errors no existe en el microservicio. O no esta" >&2
      echo "    desplegado todavia, o FORCE_ERRORS_ENABLED esta en false." >&2
      ;;
    *)
      echo "    Se esperaba 400 con marca 'forced' y llego $code (forced=$forced)." >&2
      ;;
  esac
  return 1
}

echo
echo "--- Comprobacion previa ---"
PREFLIGHT_OK=true
for api in $APIS; do
  preflight "$api" || PREFLIGHT_OK=false
done
if [ "$PREFLIGHT_OK" != true ]; then
  echo
  echo "Abortado ANTES de generar carga: arregla lo de arriba primero." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Ejecucion
# -----------------------------------------------------------------------------

echo
echo "--- Lanzando $TOTAL peticiones ---"
START_EPOCH=$(date +%s)

for api in $APIS; do
  USER_A="$(user_for "$api")"
  PASS_A="$(pass_for "$api")"
  for status in $STATUS_LIST; do
    printf '  api-%-7s %s  ' "$api" "$status"
    for i in $(seq 1 "$REQUESTS"); do
      do_request "$api" "$status" "$i" "$USER_A" "$PASS_A" &
    done
    # Tanda a tanda a proposito: 20 en paralelo por codigo, no 360 de golpe.
    wait
    ok=$(cat "$TMP"/res."$api"."$status".[0-9]* 2>/dev/null \
      | awk -F'|' -v s="$status" '$1==s && $3=="yes"' | wc -l | tr -d ' ')
    printf '%s/%s\n' "$ok" "$REQUESTS"
  done
done

ELAPSED=$(($(date +%s) - START_EPOCH))

# -----------------------------------------------------------------------------
# Resumen
# -----------------------------------------------------------------------------

echo
echo "============================================================"
echo " Resultado  (${ELAPSED}s)"
echo "============================================================"
printf ' %-11s %-7s %-9s %-11s %-7s %s\n' \
  API PEDIDO CORRECTO GW-RECHAZO OTROS "MEDIA ms"
printf ' %-11s %-7s %-9s %-11s %-7s %s\n' \
  "-----------" "------" "--------" "----------" "-----" "--------"

FAILED=0
for api in $APIS; do
  for status in $STATUS_LIST; do
    STATS=$(cat "$TMP"/res."$api"."$status".[0-9]* 2>/dev/null | awk -F'|' -v s="$status" '
      { n++; t += $2 }
      $1 == s && $3 == "yes"                          { ok++;    next }
      ($1 == 401 || $1 == 403 || $1 == 504) && $3 == "no" { gw++; next }
                                                      { other++ }
      END { printf "%d %d %d %.0f", ok + 0, gw + 0, other + 0, (n ? t * 1000 / n : 0) }
    ')
    [ -z "$STATS" ] && continue
    OK_N=$(echo "$STATS" | cut -d' ' -f1)
    GW_N=$(echo "$STATS" | cut -d' ' -f2)
    OTHER_N=$(echo "$STATS" | cut -d' ' -f3)
    AVG_MS=$(echo "$STATS" | cut -d' ' -f4)

    MARK=""
    if [ "$OK_N" -ne "$REQUESTS" ]; then
      MARK="  <-- revisar"
      FAILED=$((FAILED + 1))
    fi
    printf ' %-11s %-7s %-9s %-11s %-7s %s%s\n' \
      "api-$api" "$status" "$OK_N" "$GW_N" "$OTHER_N" "$AVG_MS" "$MARK"
  done
done

echo "============================================================"

if [ "$FAILED" -eq 0 ]; then
  echo "TODO CORRECTO: las $TOTAL respuestas llegaron del microservicio"
  echo "con el codigo pedido y con la marca error.forced."
else
  echo "HAY $FAILED combinaciones que no cuadran."
  echo
  echo "Como leer las columnas:"
  echo "  CORRECTO    codigo pedido Y marca 'forced'. Llego al microservicio."
  echo "  GW-RECHAZO  401/403/504 SIN marca 'forced'. Los genero Tyk y la"
  echo "              peticion nunca llego al microservicio: credenciales,"
  echo "              access_rights o timeout del upstream."
  echo "  OTROS       cualquier otro codigo, incluido 000 = sin respuesta."
fi

echo
echo "------------------------------------------------------------"
echo " Para verlo en New Relic"
echo "------------------------------------------------------------"
echo "Los errores provocados, por servicio y codigo:"
echo
echo "  SELECT count(*) AS 'Error count' FROM Log"
echo "  WHERE error.forced IS TRUE"
echo "  FACET service.name, error.forced_status"
echo "  SINCE 30 minutes ago"
echo
echo "Como los ve el gateway (5xx del upstream, no suyos):"
echo
echo "  SELECT sum(\`tyk.gateway.calls\`) AS 'Requests in period' FROM Metric"
echo "  WHERE service.name = 'tyk-gateway' AND span.kind = 'SPAN_KIND_SERVER'"
echo "    AND tyk.route LIKE '%force-errors%'"
echo "  FACET tyk.api.name, http.status_code"
echo "  SINCE 30 minutes ago"
echo
echo "Y para que este ruido NO cuente en las metricas de errores reales:"
echo
echo "  WHERE error.code IS NOT NULL AND error.forced IS NULL"

[ "$FAILED" -eq 0 ] || exit 1
exit 0
