# =============================================================================
# Tyk Gateway OSS - imagen propia
# -----------------------------------------------------------------------------
# La imagen solo lleva configuracion NO sensible: tyk.conf y las politicas.
#
# IMPORTANTE, y es la razon de que aqui no haya ningun RUN ni ningun script de
# entrypoint: desde la v5.3, y de forma completa desde la v5.5, las imagenes de
# Tyk Gateway son DISTROLESS. No existe /bin/sh, ni sed, ni base64, ni chmod.
#   - un RUN falla con: exec "/bin/sh": stat /bin/sh: no such file or directory
#   - un ENTRYPOINT de shell no podria arrancar el contenedor
#
# Por eso las definiciones de API NO se renderizan aqui dentro. Se renderizan
# fuera con scripts/render-apis.sh y llegan al contenedor montadas como fichero:
#   - en Azure: como secreto del Container App en /opt/tyk-gateway/apps
#   - en local: como volumen de docker-compose sobre el mismo directorio
#
# Ventaja lateral: ninguna credencial entra en la imagen, ni en una capa
# intermedia.
#
# Contexto de build: raiz del repositorio.
# =============================================================================

ARG TYK_VERSION=v5.12.0

FROM docker.tyk.io/tyk-gateway/tyk-gateway:${TYK_VERSION}

# Configuracion base. Los secretos se dejan vacios y se inyectan en ejecucion
# mediante los overrides nativos TYK_GW_*.
COPY tyk/tyk.conf /opt/tyk-gateway/tyk.conf

COPY tyk/policies/ /opt/tyk-gateway/policies/

EXPOSE 8080

WORKDIR /opt/tyk-gateway

# Explicito y no heredado, para no depender de lo que traiga la imagen base.
ENTRYPOINT ["/opt/tyk-gateway/tyk", "--conf=/opt/tyk-gateway/tyk.conf"]
