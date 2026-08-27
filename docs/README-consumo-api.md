# Consumo de las APIs a través del gateway

Flujo completo de extremo a extremo: crear una orden, consultarla y comprobar el
estado de la cadena. Todo pasa por el gateway de Tyk, nunca directamente contra
los microservicios.

---

## 1. Variables

```bash
GW=https://ca-tykpoc-gw.salmonsmoke-f112f9f8.westeurope.azurecontainerapps.io

# Credenciales de CONSUMIDOR del gateway.
# NO son el Basic Auth de los microservicios: Tyk sustituye la cabecera
# Authorization por la del upstream antes de reenviar, así que el cliente nunca
# conoce la credencial del micro.
USERS_AUTH='users-api:TU_PASSWORD_USERS'
ORDERS_AUTH='orders-api:TU_PASSWORD_ORDERS'
```

Los dos usuarios **tienen que ser distintos**. Tyk indexa las claves de Basic
Auth como `org_id + usuario`, así que con el mismo usuario para las dos APIs la
segunda credencial sobrescribe la primera y una de las dos empieza a devolver
401 sin que nada avise.

| Ruta en el gateway | Upstream | `strip_listen_path` |
| --- | --- | --- |
| `/api-users/v1` | `poc-microservice-users` | sí |
| `/api-orders/v1` | `poc-microservice-orders` | sí |

Con `strip_listen_path` activo, `/api-orders/v1/users/X/orders` llega al
microservicio como `/users/X/orders`.

---

## 2. Crear un usuario

Este paso es **obligatorio antes de crear la orden**: cada endpoint de orders
valida al propietario contra la API de usuarios, y esa validación también pasa
por el gateway. Sin usuario, la creación de la orden devuelve 404.

```bash
curl -sS -X POST "$GW/api-users/v1/users" \
  --user "$USERS_AUTH" \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "Ada Lovelace",
    "email": "ada.lovelace@example.com"
  }'
```

Respuesta, `201`. Las respuestas de users van envueltas en `data`:

```json
{ "data": { "id": "3f8c1e42-9b7a-4d51-8e2f-6a0c9d5b1e73" } }
```

Guarda el id:

```bash
USER_ID=3f8c1e42-9b7a-4d51-8e2f-6a0c9d5b1e73
```

---

## 3. Crear una orden

```bash
curl -sS -X POST "$GW/api-orders/v1/users/$USER_ID/orders" \
  --user "$ORDERS_AUTH" \
  -H 'Content-Type: application/json' \
  -d '{
    "items": [
      {
        "productId": "SKU-1001",
        "productName": "Teclado mecanico",
        "quantity": 2,
        "unitPrice": 89.90
      },
      {
        "productId": "SKU-2042",
        "productName": "Raton ergonomico",
        "quantity": 1,
        "unitPrice": 45.50
      }
    ]
  }'
```

Respuesta, `201`. A diferencia de users, orders devuelve el objeto sin envoltura:

```json
{
  "id": "b21d7c90-4e6f-4a18-9c33-5d7e8f1a2b64",
  "userId": "3f8c1e42-9b7a-4d51-8e2f-6a0c9d5b1e73",
  "items": [ ... ],
  "totalAmount": 225.30,
  "status": "PENDING",
  "createdAt": "2026-08-27T12:04:11.482",
  "updatedAt": "2026-08-27T12:04:11.482"
}
```

Tres cosas que el servicio decide y no se envían:

- `totalAmount` se calcula como la suma de `quantity * unitPrice`. Aquí,
  `2 * 89.90 + 1 * 45.50 = 225.30`.
- `status` siempre arranca en `PENDING`. Los valores posibles son `PENDING`,
  `CONFIRMED`, `SHIPPED`, `DELIVERED` y `CANCELLED`.
- `items` no puede ir vacío, y cada línea exige `productId`, `productName`,
  `quantity` y `unitPrice`. Si falta alguno, la respuesta es `400` con el detalle
  por campo.

Guarda el id de la orden:

```bash
ORDER_ID=b21d7c90-4e6f-4a18-9c33-5d7e8f1a2b64
```

---

## 4. Consultar la orden

```bash
curl -sS "$GW/api-orders/v1/users/$USER_ID/orders/$ORDER_ID" \
  --user "$ORDERS_AUTH"
```

Devuelve `200` con el mismo objeto. Y la lista completa del usuario, con filtro
opcional por estado:

```bash
curl -sS "$GW/api-orders/v1/users/$USER_ID/orders" --user "$ORDERS_AUTH"

curl -sS "$GW/api-orders/v1/users/$USER_ID/orders?status=PENDING" \
  --user "$ORDERS_AUTH"
```

La orden se devuelve solo si pertenece a ese usuario. Pedir una orden ajena da
`404`, no `403`: es deliberado, para no confirmar que ese id existe.

---

## 5. Comprobar el estado

```bash
curl -sS "$GW/api-users/v1/status"  --user "$USERS_AUTH"
curl -sS "$GW/api-orders/v1/status" --user "$ORDERS_AUTH"
```

`users` comprueba una dependencia:

```json
{ "services": [ { "service": "database", "status": "ok" } ] }
```

`orders` comprueba tres, y la tercera recorre la cadena entera
`orders → tyk → users`:

```json
{
  "services": [
    { "name": "database",           "status": "ok" },
    { "name": "http",               "status": "ok" },
    { "name": "external_api_users", "status": "ok" }
  ]
}
```

Dos diferencias entre los dos endpoints que conviene conocer:

- **users** devuelve `503` cuando algo está degradado. **orders** devuelve
  siempre `200` y el detalle en el cuerpo, porque su `/status` lo consume la
  sonda del gateway. En orders, por tanto, **el código HTTP no sirve para
  alertar**: usa el atributo `health.overall`, que sí distingue `ok` de
  `degraded`.
- Los nombres de campo difieren, `service` en users y `name` en orders. Es una
  inconsistencia conocida del PoC.

Y un aviso sobre latencia: el `/status` de orders hace **tres comprobaciones
secuenciales**, una de ellas contra `httpbin.org`. Justo después de un
despliegue, con la JVM en frío, puede tardar decenas de segundos.

---

## 6. Qué mirar en New Relic

Este es el objetivo real del flujo. Una sola petición del paso 3 genera una
traza que atraviesa cuatro servicios.

```sql
-- La traza completa de la creación de la orden
SELECT * FROM Span
WHERE service.name IN ('tyk-gateway', 'microservice-orders', 'microservice-users')
SINCE 30 minutes ago LIMIT 100

-- Los spans por capa dentro de cada micro
SELECT name, duration FROM Span
WHERE service.name = 'microservice-orders'
  AND name LIKE '%OrderService%' OR name LIKE '%UserValidationService%'
SINCE 30 minutes ago
```

El span que más dice es **`UserValidationService.validateUser`**: es el salto
`orders → tyk → users`, así que su duración frente al total revela cuánto de la
latencia se va en validar el usuario en lugar de en trabajar con la orden.

Los logs de la misma petición se cruzan por `trace.id`:

```sql
SELECT timestamp, service.name, level, message FROM Log
WHERE trace.id = 'PEGA_AQUI_EL_TRACE_ID'
SINCE 30 minutes ago LIMIT 100
```

Y el contexto que orders propaga por Baggage aparece en los spans de users, sin
que users conozca a orders:

```sql
SELECT * FROM Span
WHERE service.name = 'microservice-users'
  AND baggage.caller.service = 'poc-microservice-orders'
SINCE 30 minutes ago
```

---

## 7. Si algo falla

El código HTTP y el cuerpo identifican la causa sin adivinar. Esta tabla sale de
medir cada caso contra el gateway.

| Código | Cuerpo | Causa | Dónde mirar |
| --- | --- | --- | --- |
| 401 | `{"error": "User not authorised"}` | credencial de consumidor mala o inexistente | secrets `USERNAME_API_*` / `PASSWORD_API_*` |
| 401 | vacío | **el microservicio** rechaza a Tyk | secrets `UPSTREAM_*_BASIC_*` del gateway contra `BASIC_AUTH_*` del micro |
| 403 | — | la credencial autentica, pero su `access_rights` no coincide con el `api_id` | `provision_key.sh` y el `api_id` de la definición de API |
| 400 | — | cabecera Basic malformada, o `:` en la contraseña | Tyk no admite dos puntos en la contraseña |
| 404 | en `POST /users/{id}/orders` | el usuario no existe en users | crea el usuario primero, paso 2 |
| 503 | en orders | la cadena `orders → tyk → users` está caída | `GET /api-orders/v1/status` y `GATEWAY_BASE_URL` en orders |

Para el 401 de la primera fila, esto separa "la clave no existe" de "la
contraseña no coincide":

```bash
# 200 = la clave existe, 404 = no existe. Aquí SÍ va el prefijo de organización.
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "x-tyk-authorization: $TYK_SECRET" \
  "$GW/tyk/keys/poc-organizationusers-api"
```

Si la clave existe y aun así da 401, la contraseña almacenada no es la que
envías. El log del gateway lo confirma con
`Attempted access with existing user, failed password check`.

`/tyk/...` es la **API de administración** y está publicada en el mismo ingress.
Con `TYK_SECRET` se puede crear cualquier credencial. Es aceptable en un PoC;
en un entorno real esa ruta no debería salir a internet.
