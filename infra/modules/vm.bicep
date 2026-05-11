// =============================================================================
// modules/vm.bicep — VM Ubuntu 22.04 LTS · Standard_B2s · cloud-init Docker
// =============================================================================

param location string
param vmName string
param vmSize string
param adminUsername string

@secure()
param sshPublicKey string

param nicId string
param dataDiskSizeGb int


resource dataDisk 'Microsoft.Compute/disks@2023-10-02' = {
  name: 'disk-tyk-poc-data'
  location: location
  sku: {
    name: 'StandardSSD_LRS'
  }
  properties: {
    diskSizeGB: dataDiskSizeGb
    creationData: {
      createOption: 'Empty'
    }
  }
}

// ── cloud-init: instala Docker + Compose, monta disco de datos ───────────────
// Se pasa como customData en base64. Bicep lo codifica automáticamente con
// base64(string). El script se ejecuta en el primer arranque de la VM.

var cloudInitScript = '''
#cloud-config
package_update: true
package_upgrade: true

packages:
  - ca-certificates
  - curl
  - gnupg
  - git
  - unzip
  - jq

runcmd:
  # ── Docker Engine ──────────────────────────────────────────────────────────
  - install -m 0755 -d /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  - chmod a+r /etc/apt/keyrings/docker.gpg
  - echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
  - apt-get update -y
  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  - systemctl enable docker
  - systemctl start docker
  - usermod -aG docker azureuser

  # ── Disco de datos → /data (volúmenes Docker) ──────────────────────────────
  - |
    DISK=$(lsblk -rno NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}' | grep -v sda | head -1)
    if [ -n "$DISK" ] && ! blkid "$DISK"; then
      mkfs.ext4 -L docker-data "$DISK"
      mkdir -p /data
      echo "LABEL=docker-data /data ext4 defaults,nofail 0 2" >> /etc/fstab
      mount -a
    fi
  - mkdir -p /data/letsencrypt /data/tyk /data/otel

  # ── Directorio de trabajo del proyecto ─────────────────────────────────────
  - mkdir -p /opt/tyk-poc
  - chown azureuser:azureuser /opt/tyk-poc

final_message: "VM lista. Docker version: $(/usr/bin/docker --version)"
'''

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  properties: {

    hardwareProfile: {
      vmSize: vmSize
    }

    storageProfile: {

      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }

      osDisk: {
        name: 'disk-${vmName}-os'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
        diskSizeGB: 30
        deleteOption: 'Delete'
      }

      dataDisks: [
        {
          lun: 0
          name: dataDisk.name
          createOption: 'Attach'
          managedDisk: {
            id: dataDisk.id
          }
          deleteOption: 'Delete'
        }
      ]
    }

    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      customData: base64(cloudInitScript)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }

    networkProfile: {
      networkInterfaces: [
        {
          id: nicId
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }

    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }

  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────

output vmId string = vm.id
output vmName string = vm.name
