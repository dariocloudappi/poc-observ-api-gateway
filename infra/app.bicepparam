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

param upstreamUsersTargetUrl = readEnvironmentVariable('UPSTREAM_USERS_TARGET_URL', '')
param upstreamUsersUser = readEnvironmentVariable('UPSTREAM_USERS_BASIC_USER', '')
param upstreamUsersPassword = readEnvironmentVariable('UPSTREAM_USERS_BASIC_PASSWORD', '')

param upstreamOrdersTargetUrl = readEnvironmentVariable('UPSTREAM_ORDERS_TARGET_URL', '')
param upstreamOrdersUser = readEnvironmentVariable('UPSTREAM_ORDERS_BASIC_USER', '')
param upstreamOrdersPassword = readEnvironmentVariable('UPSTREAM_ORDERS_BASIC_PASSWORD', '')

param environmentName = readEnvironmentVariable('ENVIRONMENT', 'poc')
param serviceNamespace = readEnvironmentVariable('SERVICE_NAMESPACE', 'poc-observability')
param applyLogExclusionTag = bool(readEnvironmentVariable('NR_EXCLUDE_PLATFORM_LOGS', 'false'))
param observabilityEnabled = bool(readEnvironmentVariable('OBSERVABILITY_ENABLED', 'true'))
param gatewayUseLogstash = readEnvironmentVariable('GATEWAY_USE_LOGSTASH', 'true')
param tykEnableDetailedRecording = readEnvironmentVariable('TYK_ENABLE_DETAILED_RECORDING', 'false')
param tykLogLevel = readEnvironmentVariable('TYK_LOG_LEVEL', 'info')
