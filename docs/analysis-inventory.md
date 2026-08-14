# Inventario de analisis - poc-tyk-api-gateway

Fecha del analisis: 2026-08-06
Rama analizada: `main` (HEAD `d1de574`)
Remoto: `https://github.com/dariocloudappi/poc-tyk-api-gateway.git`

Este documento corresponde a la **Fase 1 (analisis)**. Registra el estado del repositorio
*antes* de la refactorizacion, los secretos detectados, su riesgo y el plan de migracion.

---

## 1. Inventario de ficheros (estado inicial)

Ficheros versionados (`git ls-files`), excluyendo `.git/`:

| Ruta | Tipo | Contiene secretos |
|------|------|-------------------|
| `.env.example` | Plantilla de entorno | Si (valores por defecto debiles) |
| `.gitignore` | Config git | No |
| `README.md` | Documentacion | Si (documenta secretos por defecto) |
| `docker-compose.yaml` | Orquestacion local | No en claro (usa `${VAR}`) |
| `execute-massive-requets.sh` | Script de carga | No (lee `.credentials.tyk.env`) |
| `infra/main.bicep` | IaC Azure (VM IaaS) | No |
| `infra/main.bicepparam` | Parametros IaC | No (lee `SSH_PUBLIC_KEY` del entorno) |
| `infra/modules/networking.bicep` | IaC red + NSG | No |
| `infra/modules/vm.bicep` | IaC VM + cloud-init | No |
| `otel/config.yaml` | Config OTel Collector | No (usa `${NR_LICENSE_KEY}`) |
| `provision_key.sh` | Alta de keys en Tyk | No en claro (lee `.env`) |
| `run-gateway.sh` | Arranque local | No |
| `tyk/apps/microservice-orders.json` | API definition Tyk | **SI - credencial real** |
| `tyk/apps/microservice-users.json` | API definition Tyk | **SI - credencial real** |
| `tyk/certs/cert.pem` | Certificado TLS | Certificado publico (autofirmado) |
| `tyk/certs/key.pem` | **Clave privada TLS** | **SI - clave privada** |
| `tyk/policies/policies.json` | Policies Tyk | No (`{}` vacio) |
| `tyk/tyk.conf` | Config gateway | **SI - secretos del gateway** |

Ficheros presentes en el historico y ya eliminados: `README copy.md`.

---

## 2. Credenciales y secretos detectados

Clasificacion de riesgo: **CRITICO** (credencial real explotable), **ALTO** (secreto real
de bajo impacto o configuracion que expone superficie), **MEDIO** (valor por defecto
debil que llegaria a produccion), **BAJO** (placeholder o higiene).

### 2.1 CRITICO - Credencial de upstream en claro (Basic Auth)

| Campo | Valor |
|-------|-------|
| Tipo | Basic Auth hacia el backend (par usuario:password con formato UUID) |
| Fichero / linea | `tyk/apps/microservice-users.json:21` y `tyk/apps/microservice-orders.json:21` |
| Forma | Cabecera `Authorization: Basic <base64>` inyectada como `global_headers` |
| Estado | Commiteada desde `613e1b5` ("feat: first commit"), presente en HEAD |

La cadena base64 decodifica a un par `<uuid>:<uuid>` que autentica al gateway contra los
App Services `poc-micro-users-*.azurewebsites.net` y
`poc-microservice-orders-*.azurewebsites.net`. Es una credencial real y funcional, no un
placeholder: no aparece definida en ningun `.env.example` de los repositorios hermanos, lo
que confirma que se inyecto directamente en la definicion de API.

**Riesgo:** cualquiera con acceso al repositorio (publico en GitHub) puede llamar
directamente a los backends saltandose el gateway, sus rate limits, su autenticacion y su
trazabilidad. La URL del upstream tambien esta en el mismo fichero, por lo que la
explotacion es inmediata.

**Accion:** rotar la credencial en ambos App Services **antes** de cualquier despliegue
nuevo. La migracion a variables de entorno no invalida la credencial ya expuesta.

### 2.2 CRITICO - Clave privada TLS versionada

| Campo | Valor |
|-------|-------|
| Tipo | Clave privada RSA (PKCS#8, 4096 bits) |
| Fichero | `tyk/certs/key.pem` (fichero completo), par publico en `tyk/certs/cert.pem` |
| Certificado | `CN=localhost`, SAN `DNS:localhost, IP:127.0.0.1`, autofirmado, valido 2026-05-10 a 2027-05-10 |
| Estado | Commiteada desde `613e1b5`, presente en HEAD |

**Riesgo:** el impacto directo es limitado porque el certificado es autofirmado y solo
cubre `localhost`, de modo que ningun cliente lo valida como cadena de confianza publica.
El riesgo real es de proceso: normaliza commitear material criptografico privado, y si en
algun momento ese mismo par se reutilizo para un FQDN real, cualquiera puede suplantar el
endpoint o descifrar trafico capturado.

**Accion:** eliminar ambos ficheros del arbol de trabajo, ignorarlos en `.gitignore` y
generarlos bajo demanda con un script local. Considerar el par actual como comprometido y
no reutilizarlo. Nota: la eliminacion no borra el fichero del historico de git; para
purgarlo hace falta reescritura de historico (`git filter-repo`) y `push --force`, algo
que se documenta como accion pendiente del propietario del repositorio.

### 2.3 ALTO - Secretos del gateway embebidos en `tyk.conf`

| Campo | Valor |
|-------|-------|
| Tipo | Admin secret y node secret de Tyk Gateway |
| Fichero / linea | `tyk/tyk.conf:3` (`"secret": "tyk-secret-change-me"`), `tyk/tyk.conf:4` (`"node_secret": "tyk-node-secret-change-me"`) |

El valor es un placeholder conocido, pero es el valor **efectivo** que usa el gateway: el
fichero se monta tal cual en `docker-compose.yaml:68`. `TYK_GW_SECRET` si se sobrescribe
por entorno, pero `node_secret` no se sobrescribe en ningun sitio. El `secret` del gateway
da acceso total a la API de administracion de Tyk (`/tyk/keys`, `/tyk/apis`, `/tyk/reload`),
es decir, permite crear keys, leer configuraciones y modificar el gateway.

**Riesgo:** si el puerto de administracion es alcanzable y el secreto sigue siendo el valor
por defecto publicado en el repositorio, el gateway queda totalmente comprometido.

**Accion:** vaciar los valores en `tyk.conf` y alimentarlos exclusivamente por
`TYK_GW_SECRET` y `TYK_GW_NODESECRET` (overrides nativos de Tyk), con valores generados
aleatoriamente por despliegue.

### 2.4 MEDIO - Credenciales por defecto debiles en `.env.example`

| Fichero / linea | Variable | Valor |
|-----------------|----------|-------|
| `.env.example:42` | `TYK_SECRET` | `tyk-secret-change-me` |
| `.env.example:43` | `TYK_NODE_SECRET` | `tyk-node-secret-change-me` |
| `.env.example:81-82` | `USERNAME_API_USERS` / `PASSWORD_API_USERS` | `admin` / `admin` |
| `.env.example:84-85` | `USERNAME_API_ORDERS` / `PASSWORD_API_ORDERS` | `orders` / `orders` |

Un `.env.example` debe contener placeholders inertes, no valores usables. Aqui son valores
que funcionan si se copian tal cual, y `provision_key.sh` los convierte en credenciales
Basic Auth reales de consumo del gateway.

**Riesgo:** el PoC se despliega en Internet con usuario `admin` / password `admin`.

**Accion:** sustituir por placeholders explicitamente invalidos y documentar como generar
valores fuertes.

### 2.5 BAJO - Placeholder de New Relic

`.env.example:21` contiene `NR_LICENSE_KEY=eu01xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxNRAL`. Es un
placeholder enmascarado (no es una licencia valida). Se ha verificado el historico completo
(`git log --all -S "NRAL"`) y solo aparece en `.env.example`: **no hay ninguna license key
real commiteada**. Se mantiene el patron pero se marca claramente como placeholder.

---

## 3. Hallazgos de seguridad y configuracion (no credenciales)

| # | Hallazgo | Fichero / linea | Riesgo |
|---|----------|-----------------|--------|
| 1 | NSG permite SSH desde cualquier origen: `myPublicIp = '*'` se traduce a `sourceAddressPrefix: '*'` en la regla `allow-ssh` | `infra/main.bicepparam:19`, `infra/modules/networking.bicep:45` | ALTO - superficie de ataque SSH abierta a Internet |
| 2 | Redis publicado en el host sin password ni TLS (`storage.password` vacio) | `docker-compose.yaml:11`, `tyk/tyk.conf:22-32` | ALTO - Redis contiene las keys de API y las analiticas |
| 3 | Puertos del colector OTel publicados en el host: 4318, 8888, 13133 y 24224 (Fluent Forward acepta logs sin autenticacion) | `docker-compose.yaml:27-32` | MEDIO - ingesta de logs falsificables y metricas internas expuestas |
| 4 | `enable_detailed_recording: true` guarda cuerpos completos de peticion y respuesta en Redis | `tyk/tyk.conf:43` | MEDIO - riesgo de PII en almacenamiento sin cifrar; ademas, sin Tyk Pump las analiticas crecen sin purga |
| 5 | Rutas de certificado inconsistentes: `tyk.conf` espera `fullchain.pem` y `privkey.pem`, pero el repositorio aporta `cert.pem` y `key.pem` | `tyk/tyk.conf:16-17` vs `tyk/certs/` | MEDIO - el TLS del gateway no puede levantar tal cual esta configurado |
| 6 | `provision_key.sh:22` usa `curl --insecure`, deshabilitando la validacion TLS al enviar el admin secret y los passwords | `provision_key.sh:22` | MEDIO - el secreto viaja sin verificacion de identidad del endpoint |
| 7 | `execute-massive-requets.sh:9-10` tiene `URL= $URL_GW_USERS` con espacio: no asigna la variable e **intenta ejecutar el valor como comando**, volcando el token en el mensaje de error | `execute-massive-requets.sh:9-10` | MEDIO - bug funcional y fuga del token por stderr |
| 8 | `run-gateway.sh:1` usa `export $(grep -v '^#' .env \| xargs)`, que rompe con valores entrecomillados o con espacios y expone valores en la linea de comandos | `run-gateway.sh:1` | BAJO |
| 9 | Endpoint de New Relic hardcodeado (`https://otlp.eu01.nr-data.net`) pese a existir `NR_OTLP_ENDPOINT` | `otel/config.yaml:228` | BAJO - impide cambiar de region/cuenta por entorno |
| 10 | Telemetria del colector en `level: debug` | `otel/config.yaml:284` | BAJO - verbosidad y riesgo de volcar payloads en logs |
| 11 | `.gitignore` solo cubre `.env` y `.credentials.tyk.env`; no cubre `*.pem` ni `.env.*` | `.gitignore` | MEDIO - facilita el commit accidental de material sensible |
| 12 | `otel/config.yaml:44` apunta a `tyk-redis:6379` fijo, no parametrizado | `otel/config.yaml:44` | BAJO |

---

## 4. Stack actual: version y dependencias

| Componente | Version | Fuente | Licencia |
|------------|---------|--------|----------|
| Tyk Gateway | `v5.12.0` (default de `TYK_VERSION`) | `docker-compose.yaml:41`, `.env.example:38` | OSS (MPL-2.0) |
| Redis | `7.2-alpine` | `docker-compose.yaml:6` | OSS |
| OTel Collector contrib | `0.100.0` (default de `OTEL_VERSION`) | `docker-compose.yaml:20` | OSS |

**Verificacion de "100% Community Edition": correcta.** El stack son tres contenedores
(`tyk-gateway`, `tyk-redis`, `otel-collector`). **No existe Tyk Dashboard** (componente de
pago) ni ninguna referencia a `tyk-analytics`, ni MongoDB ni PostgreSQL. La configuracion es
coherente con OSS: `use_db_app_configs: false`, `policy_source: "file"` y definiciones de
API en `tyk/apps/*.json`.

**Componente OSS ausente: Tyk Pump.** `enable_analytics: true` esta activo en `tyk.conf:41`,
por lo que el gateway escribe registros de analitica en Redis, pero no hay ningun consumidor
que los purgue ni los exporte. Consecuencias: (a) las analiticas de trafico no llegan a
ningun backend de observabilidad y (b) Redis crece sin limite. Se anade Tyk Pump en la Fase 5.

Inconsistencias de version documentadas: el `README.md:202` indica `v5.3.6` como version por
defecto y `README.md:205` indica el puerto `8080`, mientras el compose usa `v5.12.0` y el
puerto `443`.

---

## 5. Despliegue actual

La infraestructura actual **no es VMSS**, es una **VM unica IaaS** (`Standard_B2s`, Ubuntu
22.04) con disco de datos de 32 GB, definida en `infra/main.bicep` + `infra/modules/`. El
aprovisionamiento del stack es manual: `cloud-init` instala Docker y el operador entra por
SSH, clona el repositorio, crea el `.env` a mano y ejecuta `docker compose up -d`
(`README.md:98-120`).

Implicaciones para el objetivo del PoC (vida util ~1 hora):

- Una `Standard_B2s` factura por hora encendida independientemente del trafico, mas el disco
  gestionado, mas la IP publica estatica. El disco y la IP siguen facturando aunque la VM se
  apague.
- El despliegue no es reproducible de cero por pipeline: hay pasos manuales (SSH, `.env`,
  clonado) que impiden la idempotencia exigida.
- Los comentarios de los ficheros Bicep mencionan Traefik para terminar TLS, pero **no existe
  Traefik en el `docker-compose.yaml`**: el TLS lo intenta terminar el propio gateway con el
  certificado autofirmado de `localhost`, cuyas rutas ademas no coinciden (hallazgo 5). En la
  practica el endpoint publico no presenta un certificado valido para su FQDN.

---

## 6. Plan de migracion (Fases 2 a 6)

### Fase 2 - Credenciales
1. `tyk.conf`: vaciar `secret` y `node_secret`; alimentarlos por `TYK_GW_SECRET` y
   `TYK_GW_NODESECRET`.
2. `tyk/apps/*.json` pasan a plantillas `*.json.tpl`; la cabecera Basic Auth del upstream se
   construye en el arranque del contenedor a partir de `UPSTREAM_*_BASIC_USER` /
   `UPSTREAM_*_BASIC_PASSWORD`, que nunca se versionan.
3. `.env.example` con placeholders inertes; `.gitignore` ampliado a `.env*` y `*.pem`.
4. Certificados locales generados por script, no versionados.
5. Los secretos de despliegue viven en GitHub Secrets y se inyectan como `secrets` del
   Container App; nunca se escriben en ficheros del repositorio.

### Fase 3 - Infraestructura
Migracion de VM IaaS a **Azure Container Apps** (consumo, escala a cero, ingress HTTPS
gestionado) con ACR Basic, Log Analytics y Diagnostic Settings. Se descarta VMSS y VM por
coste ocioso. IaC en Bicep. Detalle y justificacion en `README.md`.

### Fase 4 - Pipeline
`deploy.yml` (OIDC, build, push, deploy, smoke test HTTPS, auto-destruccion opcional) y
`destroy.yml` (borrado del resource group).

### Fase 5 - Observabilidad
Tyk Pump (prometheus + stdout) y colector OTel como sidecar; trazas por OTLP, logs por
`fluentd` en local y `logstash/tcp` en Azure, metricas de trafico por Prometheus. Todo
gobernado por variables de entorno.

### Fase 6 - README
Documentacion completa segun el guion de la Fase 6.

---

## 7. Supuestos declarados

Puntos que no pueden determinarse a partir del repositorio y se asumen explicitamente:

1. **El par Basic Auth de `tyk/apps/*.json` es una credencial real y vigente** de los App
   Services upstream. Se infiere de que no aparece como placeholder en ningun otro sitio. Si
   fuese un valor de prueba ya rotado, el riesgo baja, pero la accion (parametrizar y rotar)
   no cambia.
2. **`tyk/certs/*.pem` solo se usa para desarrollo local.** El CN es `localhost` y no hay
   ninguna referencia a un FQDN real, por lo que se asume que nunca protegio trafico publico.
3. **La cuenta de New Relic es de region EU** (`otlp.eu01.nr-data.net`, prefijo `eu01` en el
   placeholder de licencia). Se parametriza el endpoint manteniendo EU como valor por defecto.
4. **No existen policies de Tyk en uso**: `policies.json` es `{}`. Se asume que la
   autorizacion se resuelve con `access_rights` por key, tal como hace `provision_key.sh`.
5. **La suscripcion de Azure permite crear resource groups** con la identidad federada del
   pipeline (se requiere rol Contributor a nivel de suscripcion). Si solo hubiera permisos a
   nivel de resource group, el `main.bicep` debe desplegarse en ambito de grupo con el RG ya
   creado.
6. **Tyk OSS no dispone de audit log**: el audit log formal es una funcionalidad del
   Dashboard/Tyk Enterprise. La trazabilidad de quien/que/cuando se cubre con los access logs
   estructurados del gateway y los registros de analitica de Tyk Pump. Se documenta como
   limitacion, no se simula una funcionalidad inexistente.
7. **El registro de trafico se considera dato sensible**: `enable_detailed_recording` se
   parametriza y se deja desactivado por defecto para evitar almacenar cuerpos completos.

---

## 8. Riesgos residuales tras la refactorizacion

1. La credencial de upstream y la clave privada **siguen en el historico de git** y el
   repositorio es publico. Rotar la credencial y purgar el historico son acciones del
   propietario del repositorio, fuera del alcance de un cambio de ficheros.
2. En Azure Container Apps el TLS publico lo termina el ingress gestionado; el tramo
   ingress-contenedor viaja por la red interna del entorno. Se documenta en el README junto
   con la opcion de cifrado peer-to-peer.
3. Los secretos inyectados como `secrets` del Container App son legibles por cualquiera con
   permisos de lectura sobre el recurso en Azure. Para produccion se documenta la referencia
   a Azure Key Vault con identidad gestionada.
