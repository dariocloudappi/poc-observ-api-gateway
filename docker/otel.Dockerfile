# =============================================================================
# OpenTelemetry Collector (contrib) - custom image
# -----------------------------------------------------------------------------
# Ships the collector pipeline only. The New Relic license key and endpoint are
# resolved from environment variables at runtime.
# Build context: repository root.
# =============================================================================

ARG OTEL_VERSION=0.100.0

FROM otel/opentelemetry-collector-contrib:${OTEL_VERSION}

COPY otel/config.yaml /etc/otel/config.yaml

# OTLP gRPC, OTLP HTTP, Fluent Forward, Tyk logstash (tcplog), health, metrics.
EXPOSE 4317 4318 24224 5170 13133 8888

CMD ["--config=/etc/otel/config.yaml"]
