#!/usr/bin/env bash
# =============================================================================
# render-apis.sh
# -----------------------------------------------------------------------------
# Renderiza las definiciones de API de Tyk desde tyk/apps/*.json.tpl.
#
# Por que existe y por que NO va dentro del contenedor: desde la v5.3, y de
# forma completa desde la v5.5, las imagenes de Tyk Gateway son DISTROLESS. No
# hay /bin/sh, ni sed, ni base64, ni chmod. Un entrypoint de shell dentro de la
# imagen no puede arrancar. Asi que el renderizado ocurre FUERA:
#
#   - en CI: este script lo ejecuta el pipeline y el resultado viaja como
#     secreto del Container App, montado como fichero en /opt/tyk-gateway/apps
#   - en local: este script lo ejecutas tu y docker-compose monta el directorio
#
# El mismo renderizador para los dos caminos, para que no divergan.
#
# Uso:
#   ./scripts/render-apis.sh [directorio-de-salida]
# Por defecto escribe en tyk/apps-rendered/, que esta en .gitignore porque los
# ficheros generados contienen credenciales.
# =============================================================================

set -euo pipefail

TEMPLATE_DIR="${TEMPLATE_DIR:-tyk/apps}"
OUT_DIR="${1:-tyk/apps-rendered}"

TYK_ORG_ID="${TYK_ORG_ID:-poc-organization}"
TYK_DETAILED_TRACING="${TYK_DETAILED_TRACING:-false}"

fail() { echo "render-apis: ERROR: $*" >&2; exit 1; }

for name in UPSTREAM_USERS_TARGET_URL UPSTREAM_USERS_BASIC_USER UPSTREAM_USERS_BASIC_PASSWORD \
            UPSTREAM_ORDERS_TARGET_URL UPSTREAM_ORDERS_BASIC_USER UPSTREAM_ORDERS_BASIC_PASSWORD; do
  [ -n "${!name:-}" ] || fail "falta la variable de entorno $name"
done

# Escapa los caracteres especiales del lado de reemplazo de sed.
sed_escape() { printf '%s' "$1" | sed -e 's/[\&|]/\&/g'; }

# Cabecera Authorization: Basic a partir de usuario y contrasena.
basic_header() { printf '%s:%s' "$1" "$2" | base64 | tr -d '\n' | sed -e 's/^/Basic /'; }

USERS_AUTH_HEADER="$(basic_header "$UPSTREAM_USERS_BASIC_USER" "$UPSTREAM_USERS_BASIC_PASSWORD")"
ORDERS_AUTH_HEADER="$(basic_header "$UPSTREAM_ORDERS_BASIC_USER" "$UPSTREAM_ORDERS_BASIC_PASSWORD")"

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/*.json 2>/dev/null || true

rendered=0
for template in "$TEMPLATE_DIR"/*.json.tpl; do
  [ -e "$template" ] || fail "no hay plantillas en $TEMPLATE_DIR"
  target="$OUT_DIR/$(basename "$template" .tpl)"

  sed \
    -e "s|%%TYK_ORG_ID%%|$(sed_escape "$TYK_ORG_ID")|g" \
    -e "s|%%TYK_DETAILED_TRACING%%|$(sed_escape "$TYK_DETAILED_TRACING")|g" \
    -e "s|%%UPSTREAM_USERS_TARGET_URL%%|$(sed_escape "$UPSTREAM_USERS_TARGET_URL")|g" \
    -e "s|%%UPSTREAM_ORDERS_TARGET_URL%%|$(sed_escape "$UPSTREAM_ORDERS_TARGET_URL")|g" \
    -e "s|%%UPSTREAM_USERS_AUTH_HEADER%%|$(sed_escape "$USERS_AUTH_HEADER")|g" \
    -e "s|%%UPSTREAM_ORDERS_AUTH_HEADER%%|$(sed_escape "$ORDERS_AUTH_HEADER")|g" \
    "$template" > "$target"

  chmod 0640 "$target"

  # Falla rapido si queda algun placeholder sin resolver.
  if grep -q '%%[A-Z_]*%%' "$target"; then
    fail "placeholder sin resolver en $(basename "$target")"
  fi
  # Y comprueba que el resultado es JSON valido antes de que llegue a Tyk.
  if command -v jq >/dev/null 2>&1; then
    jq empty "$target" || fail "$(basename "$target") no es JSON valido"
  fi

  echo "render-apis: generado $(basename "$target")"
  rendered=$((rendered + 1))
done

echo "render-apis: $rendered definicion(es) en $OUT_DIR"
