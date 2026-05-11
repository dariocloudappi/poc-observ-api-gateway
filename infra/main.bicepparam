// =============================================================================
// main.bicepparam — parámetros para la PoC
// USO: az deployment group create ... --parameters main.bicepparam
// NUNCA commitees sshPublicKey con valor real en git
// =============================================================================

using './main.bicep'

param location = 'westeurope'
param vmName = 'vm-tyk-poc'
param adminUsername = 'azureuser'

param sshPublicKey = readEnvironmentVariable('SSH_PUBLIC_KEY') // Lee la clave SSH de una variable de entorno para mayor seguridad

// DNS label → tyk-poc.westeurope.cloudapp.azure.com
param dnsLabel = 'tyk-poc'

// Tu IP pública para SSH — cámbiala por tu IP real o deja '*' solo para pruebas
param myPublicIp = '*'

param vmSize = 'Standard_B2s'
param dataDiskSizeGb = 32
