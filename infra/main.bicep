// =============================================================================
// main.bicep - PoC Tyk OSS on Azure Container Apps (stage 1: foundation)
// -----------------------------------------------------------------------------
// Scope: subscription. Creates the resource group and everything that must
// exist before the container images can be built and pushed:
//   - Log Analytics workspace
//   - Azure Container Registry (Basic)
//   - User assigned managed identity with AcrPull
//   - Container Apps managed environment wired to Log Analytics
//   - Optional subscription Activity Log export (audit trail)
//
// Stage 2 (infra/app.bicep) deploys the container app itself.
// =============================================================================

targetScope = 'subscription'

@description('Azure region for every resource')
param location string = 'westeurope'

@description('Prefix used to build every resource name')
@minLength(3)
@maxLength(12)
param namePrefix string = 'tykpoc'

@description('Name of the resource group that holds the whole PoC')
param resourceGroupName string = 'rg-${namePrefix}'

@description('Owner tag, used for cost attribution and cleanup')
param owner string = 'unknown'

@description('Expected lifetime of the PoC, used by cleanup automation')
param ttl string = '1h'

@description('Log Analytics retention in days. 30 is the minimum billable value')
@minValue(30)
@maxValue(730)
param logRetentionDays int = 30

@description('Daily ingestion cap for Log Analytics in GB. Protects the PoC budget')
param logDailyQuotaGb int = 1

@description('Export the subscription Activity Log to the workspace. Provides the who/what/when audit trail of the deployment itself')
param enableActivityLogExport bool = true

@description('Assign AcrPull to the managed identity. Requires Owner or RBAC Administrator on the subscription. Disable if the assignment is managed out of band')
param assignAcrPullRole bool = true

@description('Send diagnostic settings to Log Analytics. Set it to false once the Azure Native New Relic Service forwards the platform logs, so the same data is not ingested (and paid for) twice')
param enableLogAnalytics bool = true

@description('Exclude the Container Apps environment from the platform log forwarding of the Azure Native New Relic Service. OFF by default: the exclusion applies to the whole environment, so it would also silence Redis, the pump and the collector, which have no other path to New Relic. Turn it on only if the gateway lines arrive duplicated')
param applyLogExclusionTag bool = false

@description('Deployment timestamp. Read by the scheduled cleanup to decide when the PoC has expired. Leave the default')
param createdAt string = utcNow('yyyy-MM-ddTHH:mm:ssZ')

var tags = {
  environment: 'poc'
  ttl: ttl
  owner: owner
  project: 'poc-tyk-api-gateway'
  managedBy: 'bicep'
  createdAt: createdAt
}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

// Los nombres de despliegue de los modulos llevan un sufijo unico. Con un
// nombre fijo, un despliegue de modulo que queda bloqueado impide los
// siguientes durante 7 dias con:
//   DeploymentActive: ... cannot be saved, because this would overwrite an
//   existing deployment which is still active ... will expire at <+7 dias>
// uniqueString(deployment().name) deriva del nombre del despliegue externo, que
// la pipeline ya hace unico por ejecucion.
module foundation './modules/foundation.bicep' = {
  name: 'foundation-${uniqueString(deployment().name)}'
  scope: rg
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    logRetentionDays: logRetentionDays
    logDailyQuotaGb: logDailyQuotaGb
    assignAcrPullRole: assignAcrPullRole
    enableLogAnalytics: enableLogAnalytics
    applyLogExclusionTag: applyLogExclusionTag
  }
}

// The Activity Log covers control plane operations on every resource of the
// subscription, including the creation and deletion of this PoC.
resource activityLogToWorkspace 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (enableActivityLogExport) {
  name: 'diag-activitylog-${namePrefix}'
  properties: {
    workspaceId: foundation.outputs.logAnalyticsWorkspaceId
    logs: [
      {
        category: 'Administrative'
        enabled: true
      }
      {
        category: 'Security'
        enabled: true
      }
      {
        category: 'Policy'
        enabled: true
      }
      {
        category: 'ResourceHealth'
        enabled: true
      }
    ]
  }
}

// =============================================================================
// Outputs consumed by the pipeline
// =============================================================================

output resourceGroupName string = rg.name
output acrName string = foundation.outputs.acrName
output acrLoginServer string = foundation.outputs.acrLoginServer
output managedEnvironmentName string = foundation.outputs.managedEnvironmentName
output managedIdentityId string = foundation.outputs.managedIdentityId
output logAnalyticsWorkspaceName string = foundation.outputs.logAnalyticsWorkspaceName
