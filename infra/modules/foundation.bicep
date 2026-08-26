// =============================================================================
// modules/foundation.bicep
// -----------------------------------------------------------------------------
// Everything that must exist before the images are built and pushed.
// =============================================================================

param location string
param namePrefix string
param tags object
param logRetentionDays int
param logDailyQuotaGb int
param assignAcrPullRole bool

@description('Send the diagnostic settings to Log Analytics. Turn it off once the Azure Native New Relic Service forwards the platform logs, so the same data is not ingested (and paid for) twice')
param enableLogAnalytics bool = true

@description('Tag name that excludes a resource from the platform log forwarding of the Azure Native New Relic Service')
param logExclusionTagName string = 'newrelicLogs'

@description('Tag value that excludes a resource from the platform log forwarding')
param logExclusionTagValue string = 'exclude'

@description('Apply the exclusion tag to the Container Apps environment. OFF by default so EVERY container reaches New Relic. Turn it on only if you see the gateway log lines duplicated: the tag stops the platform forwarding of the whole environment, which also silences Redis, the pump and the collector, and those have no other path to New Relic')
param applyLogExclusionTag bool = false

// AcrPull built in role definition id (constant across every tenant).
var acrPullRoleDefinitionId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

// Trade off, and it is a real one. The gateway ships its own logs to New Relic
// through the OpenTelemetry Collector, so its platform logs would arrive twice.
// But in Container Apps the log categories live on the ENVIRONMENT, not per
// container, so excluding it silences the console output of Redis, the pump and
// the collector too, and those have no other path to New Relic: the collector
// only receives what the gateway sends it over the logstash transport.
//
// Default is therefore OFF, which favours complete coverage. Turn it on only if
// you actually observe duplicated gateway lines.
//
// The registry deliberately never carries this tag: its login and repository
// events are the audit trail of the image supply chain, nothing else emits
// them, and they have to reach New Relic.
var environmentTags = applyLogExclusionTag ? union(tags, {
  '${logExclusionTagName}': logExclusionTagValue
}) : tags

// =============================================================================
// Log Analytics workspace - target of Azure Monitor diagnostic settings
// =============================================================================

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${namePrefix}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: logRetentionDays
    workspaceCapping: {
      // Hard stop on ingestion so a runaway log loop cannot generate cost.
      dailyQuotaGb: logDailyQuotaGb
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// =============================================================================
// Container registry - Basic SKU is the cheapest that supports private pulls
// =============================================================================

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: toLower('acr${namePrefix}${uniqueString(resourceGroup().id)}')
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    // The admin user is a shared static credential. Pulls are done with a
    // managed identity instead, so it stays disabled.
    adminUserEnabled: false
    anonymousPullEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

// =============================================================================
// Managed identity used by the container app to pull from the registry
// =============================================================================

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${namePrefix}'
  location: location
  tags: tags
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignAcrPullRole) {
  name: guid(acr.id, identity.id, acrPullRoleDefinitionId)
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleDefinitionId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// =============================================================================
// Container Apps environment
// -----------------------------------------------------------------------------
// Console and system logs of every container app in the environment are sent
// to the Log Analytics workspace. This is the Azure Monitor path.
// =============================================================================

resource managedEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-${namePrefix}'
  location: location
  tags: environmentTags
  properties: {
    // With enableLogAnalytics off, New Relic is the only destination and the
    // console logs stop being copied into the workspace as well.
    appLogsConfiguration: enableLogAnalytics ? {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    } : {
      destination: 'none'
    }
    zoneRedundant: false
  }
}

// Platform level diagnostic settings for the environment itself.
resource environmentDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (enableLogAnalytics) {
  name: 'diag-cae-${namePrefix}'
  scope: managedEnvironment
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// =============================================================================
// Outputs
// =============================================================================

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output managedEnvironmentName string = managedEnvironment.name
output managedEnvironmentId string = managedEnvironment.id
output managedIdentityId string = identity.id
output managedIdentityClientId string = identity.properties.clientId
output logAnalyticsWorkspaceId string = logAnalytics.id
output logAnalyticsWorkspaceName string = logAnalytics.name
