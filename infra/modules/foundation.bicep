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

// Debe quedarse en OFF. Ya no hay riesgo de duplicado que justificase activarlo:
// el colector no procesa logs en Azure, asi que esta es la UNICA via por la que
// los cuatro contenedores llegan a New Relic. Activarlo los silencia todos, y
// ademas las categorias de log viven en el ENTORNO, no por contenedor, asi que
// no se puede excluir solo uno.
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
    // S6329: acceso publico de red. Es DELIBERADO y necesario aqui:
    //  - el pipeline consulta el workspace con "az monitor log-analytics query"
    //    desde un runner de GitHub, que esta fuera de cualquier VNet;
    //  - la ingesta llega desde recursos gestionados de Azure.
    // Cerrarlo exige Private Link mas un runner autohospedado dentro de la VNet,
    // fuera del alcance de un PoC de una hora. Documentado como limitacion
    // conocida en el README.
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
  sku: {
    name: 'Basic'
  }
  tags: tags
  properties: {
    // The admin user is a shared static credential. Pulls are done with a
    // managed identity instead, so it stays disabled.
    adminUserEnabled: false
    anonymousPullEnabled: false
    // S6329: acceso publico de red. Es DELIBERADO: las imagenes las construye y
    // sube un runner de GitHub, que esta fuera de cualquier VNet. Cerrarlo exige
    // Private Link mas un runner autohospedado. La superficie se limita por otra
    // via: adminUserEnabled y anonymousPullEnabled estan en false, y los pull
    // usan una identidad gestionada con rol AcrPull.
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
// destination 'azure-monitor' es lo que convierte el stdout/stderr de TODOS los
// contenedores del entorno en diagnostic logs de Azure Monitor, categorias
// ContainerAppConsoleLogs y ContainerAppSystemLogs. Solo desde ahi puede
// reenviarlos la integracion nativa de New Relic.
//
// Con destination 'log-analytics' los logs van DIRECTOS al workspace y nunca
// pasan por Azure Monitor, asi que no hay nada que reenviar: el diagnostic
// setting de mas abajo pide 'allLogs' y no recibe nada de consola. Ese era el
// motivo por el que los logs de redis, pump y colector no llegaban a New Relic.
//
// Las categorias de log solo existen a nivel de ENTORNO. A nivel de container
// app el parametro logs no esta soportado, solo AllMetrics.
// Ref: https://learn.microsoft.com/azure/container-apps/log-options
// =============================================================================

resource managedEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-${namePrefix}'
  location: location
  tags: environmentTags
  properties: {
    // Sin observabilidad no se guarda nada. Con ella, todo sale por Azure
    // Monitor y el destino se decide en el diagnostic setting, no aqui.
    // Efecto secundario deseado: se elimina el listKeys() del workspace, que
    // devolvia un secreto nuevo en cada compilacion y ensuciaba el diff del
    // despliegue sin que nada hubiese cambiado de verdad.
    appLogsConfiguration: enableLogAnalytics ? {
      destination: 'azure-monitor'
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
