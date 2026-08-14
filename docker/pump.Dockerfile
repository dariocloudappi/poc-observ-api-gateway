# =============================================================================
# Tyk Pump OSS - custom image
# -----------------------------------------------------------------------------
# Ships the pump configuration only. The file contains no credentials: the
# Redis host and port are overridden at runtime with TYK_PMP_* variables.
# Build context: repository root.
# =============================================================================

ARG TYK_PUMP_VERSION=v1.12.0

FROM tykio/tyk-pump-docker-pub:${TYK_PUMP_VERSION}

COPY tyk/pump/pump.conf /opt/tyk-pump/pump.conf

# Prometheus pump endpoint consumed by the OpenTelemetry Collector sidecar.
EXPOSE 9090
