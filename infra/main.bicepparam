// =============================================================================
// main.bicepparam - foundation stage
// -----------------------------------------------------------------------------
// Every value is read from the environment so that nothing sensitive is ever
// written in a versioned file.
//
// Usage (the "using" statement below already points to the template, so
// --template-file must not be passed):
//   az deployment sub create \
//     --location westeurope \
//     --parameters infra/main.bicepparam
// =============================================================================

using './main.bicep'

param location = readEnvironmentVariable('AZURE_LOCATION', 'westeurope')
param namePrefix = readEnvironmentVariable('POC_NAME_PREFIX', 'tykpoc')
param resourceGroupName = readEnvironmentVariable('AZURE_RESOURCE_GROUP', 'rg-tykpoc')
param owner = readEnvironmentVariable('POC_OWNER', 'unknown')
param ttl = readEnvironmentVariable('POC_TTL', '1h')
param logRetentionDays = int(readEnvironmentVariable('LOG_RETENTION_DAYS', '30'))
param logDailyQuotaGb = int(readEnvironmentVariable('LOG_DAILY_QUOTA_GB', '1'))
param enableActivityLogExport = bool(readEnvironmentVariable('ENABLE_ACTIVITY_LOG_EXPORT', 'true'))
param assignAcrPullRole = bool(readEnvironmentVariable('ASSIGN_ACR_PULL_ROLE', 'true'))
param enableLogAnalytics = bool(readEnvironmentVariable('ENABLE_LOG_ANALYTICS', 'true'))
param applyLogExclusionTag = bool(readEnvironmentVariable('NR_EXCLUDE_PLATFORM_LOGS', 'false'))
