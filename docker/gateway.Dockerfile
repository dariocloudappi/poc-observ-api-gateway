# =============================================================================
# Tyk Gateway OSS - custom image
# -----------------------------------------------------------------------------
# The image only carries configuration templates. Every credential is injected
# at runtime through environment variables and rendered by the entrypoint.
# Build context: repository root.
# =============================================================================

ARG TYK_VERSION=v5.12.0

FROM docker.tyk.io/tyk-gateway/tyk-gateway:${TYK_VERSION}

# Base gateway configuration. Secrets are empty on purpose: they are provided
# at runtime through the native TYK_GW_* environment overrides.
COPY tyk/tyk.conf /opt/tyk-gateway/tyk.conf

# API definitions are shipped as templates and rendered on container start.
COPY tyk/apps/ /opt/tyk-gateway/apps-templates/
COPY tyk/policies/ /opt/tyk-gateway/policies/

COPY docker/gateway-entrypoint.sh /usr/local/bin/gateway-entrypoint.sh

RUN chmod 0755 /usr/local/bin/gateway-entrypoint.sh \
    && mkdir -p /opt/tyk-gateway/apps /opt/tyk-gateway/middleware /opt/tyk-gateway/certs \
    && chmod 0770 /opt/tyk-gateway/apps \
    && rm -f /opt/tyk-gateway/apps-templates/*.json

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/gateway-entrypoint.sh"]
CMD ["/opt/tyk-gateway/tyk", "--conf=/opt/tyk-gateway/tyk.conf"]
