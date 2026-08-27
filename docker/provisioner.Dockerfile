# =============================================================================
# Mantenedor de credenciales de consumidor - imagen del sidecar
# -----------------------------------------------------------------------------
# Contiene curl y el bucle que reescribe las credenciales de Basic Auth en
# Redis. Existe porque las credenciales de Tyk viven solo en Redis y aqui Redis
# no tiene persistencia: cada replica nueva arranca vacia y el gateway empieza
# a devolver 401 "User not authorised".
#
# La imagen oficial de curl se usa tal cual: trae curl y una shell, y NO trae
# gestor de paquetes, asi que no hay nada que actualizar en tiempo de build ni
# dependencias de red durante la construccion.
#
# Build context: raiz del repositorio.
# =============================================================================

ARG CURL_VERSION=8.8.0

FROM curlimages/curl:${CURL_VERSION}

COPY scripts/provision-keys-loop.sh /provision-keys-loop.sh

# La imagen corre como el usuario "curl", sin privilegios. El script solo
# necesita salida HTTP hacia localhost, nada mas.
ENTRYPOINT ["/bin/sh", "/provision-keys-loop.sh"]
