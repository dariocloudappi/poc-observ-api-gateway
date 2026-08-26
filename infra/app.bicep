// =============================================================================
// app.bicep - PoC Tyk OSS on Azure Container Apps (stage 2: workload)
// -----------------------------------------------------------------------------
// Scope: resource group. Deployed after the images are pushed to the registry.
//
// One container app, one replica, four containers sharing the network
// namespace of the replica (they reach each other over localhost):
//   tyk-gateway     public entry point behind the managed HTTPS ingress
//   tyk-redis       key and analytics storage, ephemeral by design
//   tyk-pump        exports traffic analytics as prometheus metrics
//   otel-collector  ships traces, metrics and logs to New Relic
//
// No secret is written in this file. Secrets arrive as secure parameters from
// GitHub Secrets and are stored as container app secrets.
// =============================================================================

param location string = resourceGroup().location

@description('Prefix used to build every resource name')
param namePrefix string = 'tykpoc'

// Note on validation: these parameters are fed from environment variables
// through app.bicepparam, and Bicep evaluates readEnvironmentVariable at
// compile time. A @minLength decorator here would turn a missing variable into
// a compile error that also breaks the editor and az deployment what-if.
// The presence check therefore lives in the pipeline, which fails with an
// explicit message before calling Azure.
@description('Name of the existing Container Apps managed environment')
param managedEnvironmentName string

@description('Resource id of the user assigned identity that can pull from the registry')
param managedIdentityId string

@description('Login server of the container registry, e.g. myacr.azurecr.io')
param acrLoginServer string

@description('Fully qualified image reference of the Tyk gateway')
param gatewayImage string

@description('Fully qualified image reference of Tyk Pump')
param pumpImage string

@description('Fully qualified image reference of the OpenTelemetry Collector')
param otelImage string

@description('Public image used for Redis')
param redisImage string = 'redis:7.2-alpine'

// -----------------------------------------------------------------------------
// Tags
// -----------------------------------------------------------------------------

param owner string = 'unknown'
param ttl string = '1h'

@description('Tag name that excludes a resource from the platform log forwarding of the Azure Native New Relic Service')
param logExclusionTagName string = 'newrelicLogs'

@description('Tag value that excludes a resource from the platform log forwarding')
param logExclusionTagValue string = 'exclude'

@description('Apply the exclusion tag to the container app. OFF by default so every container reaches New Relic. Must be kept consistent with the same parameter of the foundation module')
param applyLogExclusionTag bool = false

// -----------------------------------------------------------------------------
// Secrets
// -----------------------------------------------------------------------------

@description('Tyk gateway admin API secret')
@secure()
param tykSecret string

@description('Tyk gateway node secret')
@secure()
param tykNodeSecret string

@description('New Relic ingest license key')
@secure()
param newRelicLicenseKey string

// Definiciones de API de Tyk ya renderizadas, en base64.
//
// Las renderiza el pipeline con scripts/render-apis.sh y llegan aqui como
// secretos, porque contienen la cabecera Authorization: Basic de cada upstream.
// No se renderizan dentro del contenedor: la imagen de Tyk es distroless y no
// tiene shell. Y no se hornean en la imagen: eso metería credenciales en una
// capa. Se montan como fichero en /opt/tyk-gateway/apps.
//
// Van en base64 para que el JSON, con sus comillas y saltos de linea, viaje
// intacto por variables de entorno hasta el .bicepparam.
@description('Rendered users API definition, base64 encoded')
@secure()
param usersApiDefinitionBase64 string

@description('Rendered orders API definition, base64 encoded')
@secure()
param ordersApiDefinitionBase64 string

// -----------------------------------------------------------------------------
// Non secret configuration
// -----------------------------------------------------------------------------

param newRelicOtlpEndpoint string = 'https://otlp.eu01.nr-data.net:4318'
param environmentName string = 'poc'

@description('Version reported as service.version in the gateway telemetry. Normally the Tyk version, so the telemetry says which gateway produced it')
param serviceVersion string = 'unknown'
param serviceNamespace string = 'poc-observability'

// Los upstreams (url, usuario, contrasena) y tykOrgId / tykDetailedTracing YA NO
// son parametros de la plantilla: los consume scripts/render-apis.sh en el
// pipeline, que produce las definiciones de API ya resueltas. La plantilla solo
// recibe el resultado, como secreto.
param tykLogLevel string = 'info'
param tykEnableDetailedRecording string = 'false'
param tykAccessLogsTemplate string = 'method,path,status,latency_total,latency_gateway,upstream_latency,trace_id,api_id,api_key,client_ip,user_agent,upstream_status,upstream_addr'
param otelTelemetryLogLevel string = 'info'

@description('Master switch for the observability sidecars. When false the pump and the collector are not deployed and the gateway stops emitting telemetry')
param observabilityEnabled bool = true

@description('Ship gateway logs to the collector over the logstash TCP transport. Set to false if the gateway fails to start because the collector is not listening yet: logs still reach Log Analytics through stdout')
param gatewayUseLogstash string = 'true'

@description('Keep at 1 for the PoC: Redis runs as a sidecar, so more replicas would split the key store')
@minValue(0)
@maxValue(1)
param minReplicas int = 1

@minValue(1)
@maxValue(1)
param maxReplicas int = 1

// =============================================================================
// Derived values
// =============================================================================

// See the long comment in modules/foundation.bicep: excluding this app from the
// platform log forwarding avoids duplicating the gateway lines that the
// collector already sends, but it also silences the sidecars, which have no
// other path to New Relic. Off by default in favour of complete coverage.
var baseTags = {
  environment: 'poc'
  ttl: ttl
  owner: owner
  project: 'poc-tyk-api-gateway'
  managedBy: 'bicep'
}

var tags = applyLogExclusionTag ? union(baseTags, {
  '${logExclusionTagName}': logExclusionTagValue
}) : baseTags

var gatewayPort = 8080

var observabilityContainers = [
  {
    name: 'tyk-pump'
    image: pumpImage
    resources: {
      cpu: json('0.25')
      memory: '0.5Gi'
    }
    env: [
      {
        name: 'TYK_PMP_ANALYTICSSTORAGECONFIG_HOST'
        value: 'localhost'
      }
      {
        name: 'TYK_PMP_ANALYTICSSTORAGECONFIG_PORT'
        value: '6379'
      }
      {
        name: 'TYK_PMP_PURGEDELAY'
        value: '10'
      }
      {
        name: 'TYK_LOGLEVEL'
        value: tykLogLevel
      }
    ]
  }
  {
    name: 'otel-collector'
    image: otelImage
    resources: {
      cpu: json('0.5')
      memory: '1Gi'
    }
    env: [
      {
        name: 'NR_LICENSE_KEY'
        secretRef: 'newrelic-license-key'
      }
      {
        name: 'NR_OTLP_ENDPOINT'
        value: newRelicOtlpEndpoint
      }
      {
        name: 'ENVIRONMENT'
        value: environmentName
      }
      {
        name: 'SERVICE_NAMESPACE'
        value: serviceNamespace
      }
      {
        name: 'REDIS_ENDPOINT'
        value: 'localhost:6379'
      }
      {
        name: 'TYK_PUMP_METRICS_ENDPOINT'
        value: 'localhost:9090'
      }
      {
        // service.version de la telemetria del gateway. Se usa la version de
        // Tyk: asi la telemetria dice que gateway la produjo, que es mas util
        // que un numero de version inventado.
        name: 'SERVICE_VERSION'
        value: serviceVersion
      }
      {
        name: 'OTEL_TELEMETRY_LOG_LEVEL'
        value: otelTelemetryLogLevel
      }
    ]
  }
]

// Total resources of the replica must add up to a supported combination:
// 0.5 + 0.25 + 0.25 + 0.5 = 1.5 vCPU and 1 + 0.5 + 0.5 + 1 = 3 GiB.
var baseContainers = [
  {
    name: 'tyk-gateway'
    image: gatewayImage
    resources: {
      cpu: json('0.5')
      memory: '1Gi'
    }
    // Tyk carga de aqui las definiciones de API. El directorio existe en la
    // imagen y el montaje lo sustituye por los ficheros del secreto.
    volumeMounts: [
      {
        volumeName: 'api-definitions'
        mountPath: '/opt/tyk-gateway/apps'
      }
    ]
    probes: [
      {
        type: 'Startup'
        httpGet: {
          path: '/hello'
          port: gatewayPort
          scheme: 'HTTP'
        }
        initialDelaySeconds: 10
        periodSeconds: 5
        failureThreshold: 30
      }
      {
        type: 'Readiness'
        httpGet: {
          path: '/hello'
          port: gatewayPort
          scheme: 'HTTP'
        }
        periodSeconds: 10
        failureThreshold: 3
      }
      {
        type: 'Liveness'
        httpGet: {
          path: '/hello'
          port: gatewayPort
          scheme: 'HTTP'
        }
        periodSeconds: 30
        failureThreshold: 5
      }
    ]
    env: [
      // Gateway identity and admin API
      {
        name: 'TYK_GW_SECRET'
        secretRef: 'tyk-secret'
      }
      {
        name: 'TYK_GW_NODESECRET'
        secretRef: 'tyk-node-secret'
      }
      {
        name: 'TYK_GW_LISTENPORT'
        value: string(gatewayPort)
      }
      // TLS is terminated by the managed ingress, so the gateway listens plain
      // HTTP inside the replica.
      {
        name: 'TYK_GW_HTTPSERVEROPTIONS_USESSL'
        value: 'false'
      }
      // Storage: Redis sidecar over the replica loopback interface.
      {
        name: 'TYK_GW_STORAGE_HOST'
        value: 'localhost'
      }
      {
        name: 'TYK_GW_STORAGE_PORT'
        value: '6379'
      }
      // API definitions rendered by the entrypoint
      // Las credenciales de upstream YA NO llegan al contenedor: viajan dentro
      // de las definiciones de API renderizadas, montadas como secreto. Una
      // credencial menos en el entorno del proceso.
      // Analytics consumed by Tyk Pump
      {
        name: 'TYK_GW_ENABLEANALYTICS'
        value: observabilityEnabled ? 'true' : 'false'
      }
      {
        name: 'TYK_GW_ANALYTICSCONFIG_ENABLEDETAILEDRECORDING'
        value: tykEnableDetailedRecording
      }
      // Logging
      {
        name: 'TYK_GW_LOGLEVEL'
        value: tykLogLevel
      }
      {
        name: 'TYK_GW_LOGFORMAT'
        value: 'json'
      }
      {
        name: 'TYK_GW_ACCESSLOGS_ENABLED'
        value: 'true'
      }
      {
        name: 'TYK_GW_ACCESSLOGS_TEMPLATE'
        value: tykAccessLogsTemplate
      }
      {
        name: 'TYK_GW_TRACK404LOGS'
        value: 'false'
      }
      // Log shipping towards the collector. The fluentd docker driver is not
      // available in Container Apps, so the logstash TCP transport is used.
      {
        name: 'TYK_GW_USELOGSTASH'
        value: observabilityEnabled ? gatewayUseLogstash : 'false'
      }
      {
        name: 'TYK_GW_LOGSTASHTRANSPORT'
        value: 'tcp'
      }
      {
        name: 'TYK_GW_LOGSTASHNETWORKADDR'
        value: 'localhost:5170'
      }
      // Traces
      {
        name: 'TYK_GW_OPENTELEMETRY_ENABLED'
        value: observabilityEnabled ? 'true' : 'false'
      }
      {
        name: 'TYK_GW_OPENTELEMETRY_EXPORTER'
        value: 'grpc'
      }
      {
        name: 'TYK_GW_OPENTELEMETRY_ENDPOINT'
        value: 'localhost:4317'
      }
      {
        name: 'TYK_GW_OPENTELEMETRY_RESOURCENAME'
        value: 'tyk-gateway'
      }
      {
        name: 'TYK_GW_OPENTELEMETRY_CONTEXTPROPAGATION'
        value: 'tracecontext'
      }
      // Segundos que el gateway espera al colector OTLP. Con el valor por
      // defecto (10) un colector caido se traduce en 10 s de espera POR
      // PETICION, incluido /hello: la telemetria pasa a degradar la latencia
      // de la API. Con 2 s el fallo se nota en la telemetria, no en el
      // cliente. Sintoma en los logs del gateway cuando ocurre:
      //   "traces export: context deadline exceeded: ... connection refused"
      {
        name: 'TYK_GW_OPENTELEMETRY_CONNECTIONTIMEOUT'
        value: '2'
      }
    ]
  }
  {
    name: 'tyk-redis'
    image: redisImage
    resources: {
      cpu: json('0.25')
      memory: '0.5Gi'
    }
    command: [
      'redis-server'
    ]
    args: [
      '--appendonly'
      'no'
      '--maxmemory'
      '200mb'
      '--maxmemory-policy'
      'allkeys-lru'
    ]
  }
]

// =============================================================================
// Resources
// =============================================================================

resource managedEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: managedEnvironmentName
}

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ca-${namePrefix}-gw'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentityId}': {}
    }
  }
  properties: {
    managedEnvironmentId: managedEnvironment.id
    configuration: {
      // TLS 1.2 or higher is enforced by the platform on the managed ingress,
      // and plain HTTP is rejected instead of being served.
      ingress: {
        external: true
        targetPort: gatewayPort
        transport: 'auto'
        allowInsecure: false
        clientCertificateMode: 'ignore'
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      registries: [
        {
          server: acrLoginServer
          identity: managedIdentityId
        }
      ]
      secrets: [
        {
          name: 'tyk-secret'
          value: tykSecret
        }
        {
          name: 'tyk-node-secret'
          value: tykNodeSecret
        }
        {
          name: 'newrelic-license-key'
          value: newRelicLicenseKey
        }
        {
          name: 'api-definition-users'
          value: base64ToString(usersApiDefinitionBase64)
        }
        {
          name: 'api-definition-orders'
          value: base64ToString(ordersApiDefinitionBase64)
        }
      ]
    }
    template: {
      containers: observabilityEnabled ? concat(baseContainers, observabilityContainers) : baseContainers
      // Las definiciones de API entran como ficheros. El "path" de cada secreto
      // es lo que permite que se llamen *.json, que es lo que Tyk busca: un
      // nombre de secreto no admite puntos.
      volumes: [
        {
          name: 'api-definitions'
          storageType: 'Secret'
          secrets: [
            {
              secretRef: 'api-definition-users'
              path: 'microservice-users.json'
            }
            {
              secretRef: 'api-definition-orders'
              path: 'microservice-orders.json'
            }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
      }
    }
  }
}

// =============================================================================
// Outputs
// =============================================================================

output containerAppName string = containerApp.name
output fqdn string = containerApp.properties.configuration.ingress.fqdn
output url string = 'https://${containerApp.properties.configuration.ingress.fqdn}'
