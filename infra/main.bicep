// =============================================================================
// main.bicep — PoC Tyk Gateway + OTel + Traefik en Azure IaaS
// =============================================================================

@description('Location for all resources. Default: resource group location')
param location string = resourceGroup().location

@description('Name of the VM to create')
param vmName string = 'vm-tyk-poc'

@description('Username of admin user in VM')
param adminUsername string = 'az-tyk-iaas'

@description('Secret SSH public key (ej. content of ~/.ssh/id_rsa.pub)')
@secure()
param sshPublicKey string

@description('Label DNS required for public IP (ej. tyk-poc)')
param dnsLabel string = 'tyk-poc'

@description('IP Public')
param myPublicIp string = '*'

@description('Size of VM (ej. Standard_B2s, Standard_D2s_v3, etc.)')
param vmSize string = 'Standard_B2s'

@description('Size of data disk in GB (ej. 32, 64, etc.)')
param dataDiskSizeGb int = 32

// =============================================================================
// Módules
// =============================================================================

module network './modules/networking.bicep' = {
  name: 'network'
  params: {
    location: location
    dnsLabel: dnsLabel
    myPublicIp: myPublicIp
  }
}

module vm './modules/vm.bicep' = {
  name: 'vm'
  params: {
    location: location
    vmName: vmName
    vmSize: vmSize
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    nicId: network.outputs.nicId
    dataDiskSizeGb: dataDiskSizeGb
  }
}

// =============================================================================
// Outputs
// =============================================================================
output fqdn string = network.outputs.fqdn
output publicIp string = network.outputs.publicIp
output sshCommand string = 'ssh ${adminUsername}@${network.outputs.fqdn}'
