// =============================================================================
// app.bicepparam - workload stage
// -----------------------------------------------------------------------------
// Secrets are read from environment variables, never from a versioned file.
//
// All readEnvironmentVariable calls declare a default, including the secrets.
// A missing variable must NOT be a compile error: Bicep resolves these calls
// at compile time, so a call without a default breaks the editor,
// az bicep build-params and az deployment what-if.
//
// The presence check lives in the pipeline: deploy.yml verifies every required
// secret and every value produced by the foundation stage, and fails with an
// explicit message before calling Azure.
//
// Usage (manual deployment, the "using" statement points to the template so
// --template-file must not be passed):
//   az deployment group create \
//     --resource-group "$AZURE_RESOURCE_GROUP" \
//     --parameters infra/app.bicepparam
// =============================================================================

using './app.bicep'

param namePrefix = readEnvironmentVariable('POC_NAME_PREFIX', 'tykpoc')
param managedEnvironmentName = readEnvironmentVariable('AZURE_CAE_NAME', '')
param managedIdentityId = readEnvironmentVariable('AZURE_IDENTITY_ID', '')
param acrLoginServer = readEnvironmentVariable('AZURE_ACR_LOGIN_SERVER', '')

param gatewayImage = readEnvironmentVariable('IMAGE_GATEWAY', '')
param pumpImage = readEnvironmentVariable('IMAGE_PUMP', '')
param otelImage = readEnvironmentVariable('IMAGE_OTEL', '')

param owner = readEnvironmentVariable('POC_OWNER', 'unknown')
param ttl = readEnvironmentVariable('POC_TTL', '1h')

param tykSecret = readEnvironmentVariable('TYK_SECRET', '')
param tykNodeSecret = readEnvironmentVariable('TYK_NODE_SECRET', '')
param newRelicLicenseKey = readEnvironmentVariable('NR_LICENSE_KEY', '')
param newRelicOtlpEndpoint = readEnvironmentVariable('NR_OTLP_ENDPOINT', 'https://otlp.eu01.nr-data.net:4318')

// Definiciones de API ya renderizadas por scripts/render-apis.sh en el pipeline,
// en base64. Los upstreams y sus credenciales no llegan aqui: viajan dentro de
// estas definiciones, que se montan como secreto en el contenedor.
param usersApiDefinitionBase64 = readEnvironmentVariable('API_DEFINITION_USERS_B64', '')
param ordersApiDefinitionBase64 = readEnvironmentVariable('API_DEFINITION_ORDERS_B64', '')

param environmentName = readEnvironmentVariable('ENVIRONMENT', 'poc')
param serviceVersion = readEnvironmentVariable('SERVICE_VERSION', 'unknown')
param serviceNamespace = readEnvironmentVariable('SERVICE_NAMESPACE', 'poc-observability')
param applyLogExclusionTag = bool(readEnvironmentVariable('NR_EXCLUDE_PLATFORM_LOGS', 'false'))
param observabilityEnabled = bool(readEnvironmentVariable('OBSERVABILITY_ENABLED', 'true'))
param tykEnableDetailedRecording = readEnvironmentVariable('TYK_ENABLE_DETAILED_RECORDING', 'false')
param tykLogLevel = readEnvironmentVariable('TYK_LOG_LEVEL', 'debug')
// Antes no se leia del entorno, asi que el nivel del colector se quedaba
// siempre en el default de la plantilla y no habia forma de subirlo sin
// editar el bicep.
param otelTelemetryLogLevel = readEnvironmentVariable('OTEL_TELEMETRY_LOG_LEVEL', 'debug')
