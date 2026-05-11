# Tyk OSS + OpenTelemetry + New Relic

Stack para desarrollo y despliegue de APIs con Tyk Gateway OSS, exportando trazas, métricas y logs a New Relic mediante OpenTelemetry Collector.

---

## Arquitectura

```
Microservicios (Node.js / Java)
        │
        ▼ OTLP gRPC :4317
┌───────────────────┐     OTLP gRPC      ┌──────────────────┐
│   Tyk Gateway     │ ─────────────────► │  OTel Collector  │ ──► New Relic
│   OSS :443        │                    │  :4317 / :4318   │
└───────────────────┘                    └──────────────────┘
        │
        ▼
     Redis :6379
```

---

## Prerrequisitos

Antes de desplegar, asegúrate de tener instaladas y configuradas las siguientes herramientas en tu máquina local:

### Herramientas necesarias

| Herramienta | Versión mínima | Instalación |
|-------------|---------------|-------------|
| [Azure CLI](https://learn.microsoft.com/es-es/cli/azure/install-azure-cli) | `2.57+` | `curl -sL https://aka.ms/InstallAzureCLIDeb \| sudo bash` |
| [Bicep CLI](https://learn.microsoft.com/es-es/azure/azure-resource-manager/bicep/install) | `0.25+` | `az bicep install` |
| [Docker Engine](https://docs.docker.com/engine/install/) | `24+` | Solo necesario si ejecutas el stack localmente |
| [Docker Compose](https://docs.docker.com/compose/install/) | `2.20+` | Incluido con Docker Desktop |
| `ssh-keygen` | — | Incluido en Linux/macOS. Windows: Git Bash o WSL |

### Cuenta y permisos en Azure

- Suscripción activa de Azure con permisos de **Contributor** sobre el Resource Group de destino.
- Autenticarse antes de desplegar:

```bash
az login
az account set --subscription "<tu-subscription-id>"
```

- Verificar que el Resource Group existe (o crearlo):

```bash
az group create --name "poc-observabilty" --location "westeurope"
```

### Par de claves SSH en formato OpenSSH

Azure requiere que la clave pública SSH esté en **formato OpenSSH** (`ssh-rsa AAAA...` o `ssh-ed25519 AAAA...`).
Un archivo en formato PEM (`-----BEGIN PUBLIC KEY-----`) **no es válido** y provocará un error en el despliegue.

Genera un par de claves nuevo si no tienes uno en el formato correcto:

```bash
# Genera un par ed25519 (recomendado)
ssh-keygen -t ed25519 -f ~/keys/azure-auth/azure_vm_key -C "tyk-poc" -N ""

# Verifica que el formato es correcto (debe empezar por ssh-ed25519 o ssh-rsa)
head -1 ~/keys/azure-auth/azure_vm_key.pub
```

Exporta la clave como variable de entorno antes de desplegar:

```bash
export SSH_PUBLIC_KEY=$(cat ~/keys/azure-auth/azure_vm_key.pub | tr -d '\n\r')
```

---

## Despliegue de infraestructura en Azure

1. Analiza y personaliza los archivos en la carpeta `infra/` según tus necesidades:
   - `main.bicep` y `main.bicepparam` definen la infraestructura (VM, red, seguridad, almacenamiento).
   - Ajusta parámetros como nombre de VM, usuario, tamaño, clave SSH y DNS en `main.bicepparam`.

2. Exporta la clave SSH (si no lo has hecho ya):

```bash
export SSH_PUBLIC_KEY=$(cat ~/keys/azure-auth/azure_vm_key.pub | tr -d '\n\r')
```

3. Despliega la infraestructura:

```bash
az deployment group create \
  --resource-group "poc-observabilty" \
  --template-file infra/main.bicep \
  --parameters ./infra/main.bicepparam
```

4. Una vez creada la VM, conéctate por SSH:

```bash
ssh -i ~/keys/azure-auth/azure_vm_key azureuser@<fqdn-o-ip-publica>
```

> El FQDN y la IP pública se muestran en los outputs del deployment. También puedes consultarlos con:
> ```bash
> az deployment group show \
>   --resource-group "poc-observabilty" \
>   --name main \
>   --query properties.outputs
> ```

5. En la VM, clona el repositorio y sitúate en la carpeta del proyecto.

6. Copia y completa el archivo `.env.example` como `.env` con los valores requeridos (ver sección de variables de entorno).

7. Levanta el stack Docker:

```bash
docker compose up -d
```

---

## Script de provisión automática de credenciales (`provision_keys.sh`)

Crea un archivo llamado `provision_keys.sh` en la raíz del proyecto con el siguiente contenido:

```bash
#!/bin/bash
set -e

# Array de apps y sus variables asociadas
APPS=(
  "microservice-users-001:USERNAME_API_USERS:PASSWORD_API_USERS"
  "microservice-orders-001:USERNAME_API_ORDERS:PASSWORD_API_ORDERS"
)

for entry in "${APPS[@]}"; do
  IFS=":" read -r API_ID USER_VAR PASS_VAR <<< "$entry"
  USERNAME=${!USER_VAR}
  PASSWORD=${!PASS_VAR}
  if [[ -z "$USERNAME" || -z "$PASSWORD" ]]; then
    echo "Variables no definidas para $API_ID, omitiendo."
    continue
  fi
  echo "Creando key para $API_ID ($USERNAME)"
  curl --location --fail --silent --show-error \
    --insecure \
    --header "x-tyk-authorization: $TYK_SECRET" \
    --header 'Content-Type: application/json' \
    --data '{
      "allowance": 1000,
      "rate": 1000,
      "per": 60,
      "expires": -1,
      "quota_max": -1,
      "quota_remaining": -1,
      "quota_renewal_rate": 60,
      "org_id": "poc-organization",
      "access_rights": {
        "'"$API_ID"'": {
          "api_id": "'"$API_ID"'",
          "api_name": "'"$API_ID"'",
          "versions": ["Default"]
        }
      },
      "basic_auth_data": {
        "password": "'"$PASSWORD"'"
      }
    }' \
    "https://localhost/tyk/keys/$USERNAME"
done
```

Ejecuta el script tras cada despliegue exitoso del gateway:

```bash
chmod +x provision_keys.sh
./provision_keys.sh
```

---

## Seguridad y buenas prácticas

- No almacenes secretos en el repositorio. Usa Azure Key Vault o variables de entorno del sistema para valores sensibles.
- Cambia los valores por defecto de `TYK_SECRET` y `TYK_NODE_SECRET` antes de cualquier despliegue fuera de desarrollo.
- Limita el acceso público al gateway solo por HTTPS.
- Elimina el mapeo de puertos innecesarios en producción y usa redes privadas.
- Añade `.env` a `.gitignore`.
- Nunca uses claves SSH en formato PEM con Azure; genera siempre claves en formato OpenSSH.

---

## Referencia de variables de entorno

| Variable | Descripción | Default |
|----------|-------------|---------|
| `NR_LICENSE_KEY` | License Key de New Relic (INGEST) | — obligatorio — |
| `NR_OTLP_ENDPOINT` | Endpoint OTLP de New Relic | `otlp.nr-data.net:4317` |
| `ENVIRONMENT` | Entorno (dev/staging/prod) | `dev` |
| `TYK_VERSION` | Versión imagen Tyk Gateway | `v5.3.6` |
| `TYK_SECRET` | Secret del gateway | `tyk-secret-change-me` |
| `TYK_NODE_SECRET` | Node secret | `tyk-node-secret-change-me` |
| `TYK_PORT` | Puerto expuesto del gateway | `8080` |
| `TYK_LOG_LEVEL` | Nivel de log Tyk | `info` |
| `REDIS_PORT` | Puerto Redis expuesto | `6379` |
| `OTEL_VERSION` | Versión OTel Collector contrib | `0.100.0` |
| `SSH_PUBLIC_KEY` | Clave pública SSH en formato OpenSSH para el despliegue | — obligatorio — |
| `USERNAME_API_USERS` | Usuario para microservice-users | — |
| `PASSWORD_API_USERS` | Contraseña para microservice-users | — |
| `USERNAME_API_ORDERS` | Usuario para microservice-orders | — |
| `PASSWORD_API_ORDERS` | Contraseña para microservice-orders | — |

---

Para más detalles, consulta la documentación oficial de [Tyk](https://tyk.io/docs/), [OpenTelemetry](https://opentelemetry.io/docs/) y [Azure Bicep](https://learn.microsoft.com/es-es/azure/azure-resource-manager/bicep/), y revisa la carpeta `infra/` del proyecto para personalizaciones avanzadas.