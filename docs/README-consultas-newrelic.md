# Consultas NRQL de la PoC

Consultas organizadas igual que las páginas del dashboard: **API Gateway**,
**Microservices** e **Infra**. Todas usan atributos que la PoC emite de verdad,
no genéricos.

---

## 0. Inventario: qué atributos existen

Sin esto, la mitad de las consultas fallan en silencio devolviendo vacío.

### Gateway — `service.name = 'tyk-gateway'`

Las métricas las genera el conector `spanmetrics` del colector a partir de los
spans de Tyk.

| Métrica | Tipo |
| --- | --- |
| `tyk.gateway.calls` | contador |
| `tyk.gateway.duration` | histograma exponencial |

Dimensiones disponibles, y **solo estas**:

Esta tabla **no es una suposición**. Está medida ejecutando Tyk v5.12.0 y el
colector 0.100.0 en local, las mismas dos imágenes que hay en Azure, y volcando
los atributos con el exportador `debug` a `verbosity: detailed`.

Atributos del span **server** de Tyk:

| Atributo | Ejemplo | Para qué sirve |
| --- | --- | --- |
| `tyk.api.name` | `api-users` | la API. Presente **también en los 401** |
| `tyk.api.id` | `api-users-001` | |
| `tyk.api.path` | `/api-users/v1` | el listen path |
| `tyk.api.orgid` | | |
| `http.method` | `GET` | |
| `http.status_code` | `200`, `401`, `500` | **la fuente de verdad para errores** |
| `http.target` | `/api-users/v1/users/<uuid>` | ruta **cruda**, con los ids |
| `http.scheme` | `http` | |
| `net.host.name` / `net.host.port` | | |
| `net.sock.peer.addr` | `172.21.0.1` | IP del cliente |
| `net.protocol.version` | `1.1` | |
| `user_agent.original` | `curl/8.14.1` | |
| `http.request.body.size` / `http.response.body.size` | | tamaño de la petición y la respuesta |
| `tyk.route` | `/api-users/v1/users/{id}` | **la construimos nosotros**, ver abajo |

Y lo que **no** existe:

> **`http.route` NO EXISTE, ni con ese nombre ni con ningún otro.** Estaba
> declarada en las dimensiones de `spanmetrics` y en el filtro de spans de salud,
> y en los dos sitios era **código muerto**: cualquier consulta con
> `FACET http.route` sobre el gateway salía **vacía**, y el filtro no descartaba
> nada. Las dos cosas ya están corregidas en `otel/config.yaml`.
>
> Lo más parecido que ofrece Tyk es `tyk.api.path`, pero es el listen path
> (`/api-users/v1`): la misma granularidad que `tyk.api.name`, no distingue
> recursos.

> **`tyk.route` es nuestra, no de Tyk.** La construye
> `transform/normalize_route` en el colector a partir de `http.target`,
> sustituyendo uuid e ids numéricos por `{id}` y quitando la query string.
> `/api-users/v1/users/<uuid>/orders/<uuid>` pasa a
> `/api-users/v1/users/{id}/orders/{id}`.
>
> Es la única dimensión que tiene **las dos** propiedades que hacen falta para
> agrupar por recurso: identifica el recurso y tiene cardinalidad acotada.
> `http.target` y `span.name` identifican el recurso pero generan una serie
> temporal por identificador; `tyk.api.path` está acotada pero no distingue
> recursos.

> **`status.code` sirve para los 5xx, pero NO para los 4xx.** Medido: Tyk pone el
> span en `Error` cuando responde 5xx, y lo deja en **`Unset` en los 4xx,
> incluidos los 401**. Por eso todas las consultas de error de este documento
> filtran por `http.status_code` y no por el status del span: usar el status del
> span haría **invisible cada 401 y cada 404**.
>
> (En los datos de ejemplo que revisamos `status.code` era `STATUS_CODE_UNSET` en
> todas las filas simplemente porque todas eran respuestas 200.)

> **Una petición que no encaja con ninguna API NO genera span.** Medido: una
> llamada a una ruta inexistente devuelve 404 y **no produce telemetría
> ninguna**. Consecuencia: un cliente machacando una URL equivocada es
> **invisible** en las métricas del gateway, y ninguna consulta de este documento
> lo puede detectar. Para verlo hay que mirar los **logs** de acceso de Tyk, y
> además poner `track_404_logs: true` en `tyk/tyk.conf`, que hoy está en `false`.

> **`http.target` está en el span pero se retiró de las métricas** a propósito:
> lleva los identificadores dentro de la ruta, así que cada petición creaba una
> serie temporal nueva. Sigue disponible si consultas `FROM Span`.

> **Los spans internos contaminan las métricas.** Con `detailed_tracing: true`
> Tyk emite además spans internos (`RateCheckMW`, `VersionCheck`,
> `BasicAuthKeyIsValid`) y **`spanmetrics` también los convierte en métricas**.
> Medido: aparecen series con `span.kind = SPAN_KIND_INTERNAL` y
> `span.name = VersionCheck`. Por eso **todas** las consultas de métricas del
> gateway llevan `span.kind = 'SPAN_KIND_SERVER'`: sin ese filtro los totales
> salen infladas varias veces.
>
> Detalle útil: `BasicAuthKeyIsValid` sí se marca con status `Error` cuando la
> autenticación falla, aunque el span server se quede en `Unset`.

### Microservicios — `service.name IN ('microservice-users', 'microservice-orders')`

`OTEL_SEMCONV_STABILITY_OPT_IN = http`, así que la convención es la **estable**:

| Métrica / atributo | Notas |
| --- | --- |
| `http.server.request.duration` | histograma, en **segundos** |
| `http.route` | plantilla, `/users/{id}` |
| `http.request.method` | |
| `http.response.status_code` | |
| `url.scheme` | filtrar `https` excluye las sondas internas |

Atributos de negocio propios, en `Span` **y** en `Log` a la vez, porque van por
el helper `Observability`:

| Grupo | Claves |
| --- | --- |
| Operación | `api.operation` |
| Usuarios | `user.id`, `user.result_count`, `user.email_changed`, `user.name_changed` |
| Órdenes | `order.id`, `order.status`, `order.status_previous`, `order.status_changed`, `order.item_count`, `order.total_amount`, `order.result_count`, `order.status_filter` |
| Base de datos | `db.operation`, `db.duration_ms` |
| Errores | `error.code`, `error.type`, `error.handled`, `error.dependency`, `error.invalid_fields` |
| Salud | `health.overall`, `health.database.status`, `health.database.duration_ms`, `health.external_api_users.status`, `health.degraded_count` |
| Salidas HTTP | `http.client.dependency`, `http.client.status_code`, `http.client.duration_ms`, `users_api.status_code`, `users_api.duration_ms` |
| Propagado | `baggage.caller.service`, `baggage.caller.user_id` |

Spans por capa, gracias a `OTEL_INSTRUMENTATION_METHODS_INCLUDE`:
`UsersController.getUserById`, `UserService.getUser`, `OrderService.create`,
`UserValidationService.validateUser`, `SystemService.checkDatabase`...

### Infra

| Componente | `service.name` | Origen |
| --- | --- | --- |
| Redis | `tyk-redis` | receptor `redis` del colector |
| Tyk Pump | `tyk-pump` | scrape Prometheus |
| Colector | `otel-collector` | autotelemetría, métricas `otelcol_*` |

---

### Cómo se nombran las columnas (`AS`)

El `AS` es lo único que el que mira el dashboard va a leer, así que tiene que
decir **qué se ha calculado**, no de qué va la consulta. `AS 'Requests'` no vale:
la misma palabra servía para un total del periodo, para una media por minuto y
para un recuento de spans, y en un panel con varios widgets no hay forma de saber
cuál es cuál.

La regla que sigue este documento:

| El `AS` dice | Ejemplo | En vez de |
| --- | --- | --- |
| La **magnitud** y el **periodo** | `'Requests in period'` | `'Requests'` |
| La magnitud y la **unidad** | `'p95 ms'`, `'Avg ms'` | `'p95'` |
| Que es una **tasa**, no un total | `'Error rate %'` | `'Error %'` |
| Qué se cuenta, cuando no son peticiones | `'Query count'`, `'Rejected requests'` | `'Total'` |

Dos detalles de unidades que no se pueden deducir del nombre de la métrica y que
ya nos han hecho perder tiempo:

- `tyk.gateway.duration` está en **milisegundos** (confirmado: los datos llegan
  con `unit: ms`).
- `http.server.request.duration` de los microservicios está en **segundos**, no
  en milisegundos, porque llevan `OTEL_SEMCONV_STABILITY_OPT_IN=http`. Por eso
  las consultas de latencia de los microservicios multiplican por 1000 y el alias
  dice `ms`.

### Una trampa entre el gateway y los microservicios

El gateway y los microservicios usan **convenciones semánticas distintas**, así
que **no se puede escribir una sola consulta que cruce los dos**:

| | Gateway (Tyk 5.12) | Microservicios |
| --- | --- | --- |
| Método | `http.method` | `http.request.method` |
| Código | `http.status_code` | `http.response.status_code` |
| Ruta | `tyk.route` (nuestra) | `http.route` (nativa) |
| Host | `net.host.name` | `server.address` |

Tyk sigue la convención **antigua**; los microservicios la **estable**, por
`OTEL_SEMCONV_STABILITY_OPT_IN=http`. Un `WHERE http.status_code >= 400` sobre
los microservicios devuelve **cero**, y parece que no hay errores. Para cruzar
capas, lo que sí comparten es el `trace.id`.

## 1. API Gateway

### Lo que pediste

**Top APIs más consumidas**

```sql
SELECT sum(`tyk.gateway.calls`) AS 'Requests in period'
FROM Metric
WHERE service.name = 'tyk-gateway' AND span.kind = 'SPAN_KIND_SERVER'
FACET tyk.api.name
SINCE 1 day ago
LIMIT 20
```

**Top APIs menos consumidas**

NRQL **no admite `ORDER BY` junto a `FACET`**: el orden es siempre descendente
por el primer agregado. Así que se usa una tabla y se ordena la columna en la UI
haciendo clic en la cabecera.

```sql
SELECT sum(`tyk.gateway.calls`) AS 'Requests in period'
FROM Metric
WHERE service.name = 'tyk-gateway' AND span.kind = 'SPAN_KIND_SERVER'
FACET tyk.api.name
SINCE 1 day ago
LIMIT MAX
```

> Y un aviso que importa: **una API con cero tráfico no aparece**. Sin datos no
> hay faceta. Para detectar una API publicada que nadie llama hay que comparar el
> resultado contra la lista conocida (`api-users`, `api-orders`); NRQL solo no
> puede saberlo.

**Top recursos más consumidos**

Aquí va **`tyk.route`**, la dimensión que construye el colector. No `http.route`,
que no existe, ni `http.target` o `span.name`, que generan una serie temporal por
identificador.

```sql
SELECT sum(`tyk.gateway.calls`) AS 'Requests in period'
FROM Metric
WHERE service.name = 'tyk-gateway' AND span.kind = 'SPAN_KIND_SERVER'
FACET tyk.api.name, http.method, tyk.route
SINCE 1 day ago
LIMIT 25
```

**Top recursos menos consumidos:** la misma consulta con `LIMIT MAX`, ordenando
la columna en la UI. Mismo aviso que con las APIs: un recurso con **cero
tráfico no aparece**, porque sin datos no hay faceta.

> Si necesitas la ruta **con** los identificadores, por ejemplo para investigar
> un caso concreto, no uses métricas: ve a los spans, donde está `http.target`
> sin agrupar.
>
> ```sql
> SELECT count(*) AS 'Requests in period'
> FROM Span
> WHERE service.name = 'tyk-gateway' AND span.kind = 'server'
> FACET http.target
> SINCE 1 hour ago LIMIT 50
> ```

**Top APIs con más errores**

```sql
SELECT
  sum(`tyk.gateway.calls`) AS 'Requests in period',
  filter(sum(`tyk.gateway.calls`), WHERE http.status_code >= 400 AND http.status_code < 500) AS '4xx',
  filter(sum(`tyk.gateway.calls`), WHERE http.status_code >= 500) AS '5xx',
  filter(sum(`tyk.gateway.calls`), WHERE http.status_code = 401) AS '401',
  filter(sum(`tyk.gateway.calls`), WHERE http.status_code = 503) AS '503',
  percentage(sum(`tyk.gateway.calls`), WHERE http.status_code >= 400) AS 'Error rate %'
FROM Metric
WHERE service.name = 'tyk-gateway' AND span.kind = 'SPAN_KIND_SERVER'
FACET tyk.api.name
SINCE 1 day ago
```

El `% error` es la columna que sirve para priorizar: una API con 10.000 llamadas
y 50 errores no es el mismo problema que una con 60 llamadas y 50 errores.

### Latencia por API, con percentiles

```sql
SELECT
  percentile(`tyk.gateway.duration`, 50) AS 'p50 ms',
  percentile(`tyk.gateway.duration`, 95) AS 'p95 ms',
  percentile(`tyk.gateway.duration`, 99) AS 'p99 ms',
  max(`tyk.gateway.duration`) AS 'Max ms'
FROM Metric
WHERE service.name = 'tyk-gateway' AND span.kind = 'SPAN_KIND_SERVER'
FACET tyk.api.name
SINCE 3 hours ago
```

Sin `TIMESERIES` y en tabla. Es más legible que la media: la media esconde la
cola, y la cola es lo que nota el usuario.

### Autenticación rechazada, por API

```sql
SELECT sum(`tyk.gateway.calls`) AS 'Rejected requests'
FROM Metric
WHERE service.name = 'tyk-gateway' AND span.kind = 'SPAN_KIND_SERVER'
  AND http.status_code IN (400, 401, 403)
FACET tyk.api.name, http.status_code
TIMESERIES 5 minutes
SINCE 6 hours ago
```

Los tres códigos son causas **distintas** y merecen verse separadas:

| Código | Causa |
| --- | --- |
| 401 | credencial de consumidor mala o inexistente |
| 403 | la credencial autentica, pero su `access_rights` no coincide con el `api_id` |
| 400 | cabecera Basic malformada, o dos puntos en la contraseña |

### Errores del gateway, desde sus logs

```sql
SELECT count(*) FROM Log
WHERE service.name = 'tyk-gateway' AND severity.text IN ('error', 'warning')
FACET message, api_name
SINCE 3 hours ago
LIMIT 30
```

### Mejoras concretas a tu dashboard actual

Revisando la página **API Gateway** que me pasaste:

**Hay dos widgets con la consulta idéntica.** `RPM` (43195367) y
`Rate over time` (43195436) son exactamente la misma NRQL. Uno de los dos sobra;
yo sustituiría el segundo por *Top APIs con más errores*.

**El widget 43195841 está en la página equivocada.** Consulta
`http.server.request.duration`, que es una métrica de los **microservicios**, no
del gateway. Además no tiene título. Debería estar en la página Microservices.

**`RPM` factea por `tyk.api.name` Y `http.status_code` a la vez.** Con dos APIs y
cinco códigos son diez series en una línea temporal, y no se lee. Para el RPM
basta `FACET tyk.api.name`; el desglose por código ya lo cubre
*All responses by status code*.

**`Average latency per API` mezcla avg, p95 y p99 con `FACET` y `TIMESERIES`.**
Son 3 series por API. O quitas el `TIMESERIES` y lo pasas a tabla, o te quedas
con un solo percentil en la gráfica temporal.

**`Total requets`** tiene una errata en el título, y le vendría bien un
`COMPARE WITH 1 day ago` para dar contexto al número.

---

## 2. Microservices

### Top endpoints más consumidos

```sql
SELECT count(*) AS 'Requests in period'
FROM Metric
WHERE metricName = 'http.server.request.duration' AND url.scheme = 'https'
  AND http.route IS NOT NULL
FACET service.name, http.request.method, http.route
SINCE 1 day ago
LIMIT 25
```

### Top operaciones de negocio

Esta no la tenías, y es más útil que la ruta: `api.operation` nombra la
**operación**, así que sobrevive a un cambio de versión de la URL.

```sql
SELECT count(*) AS 'Operation count'
FROM Span
WHERE service.name IN ('microservice-users', 'microservice-orders')
  AND api.operation IS NOT NULL
FACET service.name, api.operation
SINCE 1 day ago
LIMIT 25
```

### Top endpoints con más errores

```sql
SELECT
  count(*) AS 'Requests in period',
  filter(count(*), WHERE http.response.status_code >= 400 AND http.response.status_code < 500) AS '4xx',
  filter(count(*), WHERE http.response.status_code >= 500) AS '5xx',
  percentage(count(*), WHERE http.response.status_code >= 400) AS 'Error rate %'
FROM Metric
WHERE metricName = 'http.server.request.duration' AND url.scheme = 'https'
  AND http.route IS NOT NULL
FACET service.name, http.route
SINCE 1 day ago
LIMIT 25
```

### Errores por tipo de negocio

Mejor que por código HTTP: dice **qué** falló, no solo que falló.

```sql
SELECT count(*) AS 'Error count'
FROM Log
WHERE service.name IN ('microservice-users', 'microservice-orders')
  AND error.code IS NOT NULL
FACET service.name, error.code, error.type
SINCE 1 day ago
LIMIT 30
```

`error.code` distingue `USER_NOT_FOUND` de `USERS_SERVICE_UNAVAILABLE` de
`VALIDATION_ERROR`, que son tres problemas sin nada que ver aunque dos devuelvan
el mismo 404.

### Campos que más incumplen los clientes

```sql
SELECT count(*) AS 'Rejected requests'
FROM Log
WHERE error.code = 'VALIDATION_ERROR' AND error.invalid_fields IS NOT NULL
FACET service.name, error.invalid_fields
SINCE 1 day ago
```

### Dónde se va el tiempo, por capa

Esto es nuevo, y es lo que rellena el hueco de `Uninstrumented time` que veías en
las trazas.

```sql
SELECT
  count(*) AS 'Call count',
  average(duration.ms) AS 'Avg ms',
  percentile(duration.ms, 95) AS 'p95 ms'
FROM Span
WHERE service.name IN ('microservice-users', 'microservice-orders')
  AND name LIKE '%Controller.%' OR name LIKE '%Service.%'
FACET service.name, name
SINCE 3 hours ago
LIMIT 30
```

Y el span que más cuenta de orders, el salto `orders → tyk → users`:

```sql
SELECT
  percentile(duration.ms, 50) AS 'p50 ms',
  percentile(duration.ms, 95) AS 'p95 ms',
  max(duration.ms) AS 'Max ms'
FROM Span
WHERE name = 'UserValidationService.validateUser'
TIMESERIES 5 minutes
SINCE 6 hours ago
```

### Consultas a base de datos

Duración por operación, desde nuestros atributos:

```sql
SELECT
  count(*) AS 'Query count',
  average(db.duration_ms) AS 'Avg ms',
  percentile(db.duration_ms, 95) AS 'p95 ms',
  max(db.duration_ms) AS 'Max ms'
FROM Span
WHERE db.operation IS NOT NULL
FACET service.name, db.operation
SINCE 3 hours ago
```

El SQL literal, desde los spans JDBC que genera el agente:

```sql
SELECT count(*) AS 'Execution count', average(duration.ms) AS 'Avg ms'
FROM Span
WHERE service.name IN ('microservice-users', 'microservice-orders')
  AND db.statement IS NOT NULL
FACET db.statement
SINCE 3 hours ago
LIMIT 30
```

Las sentencias vienen **saneadas**: los literales se sustituyen por `?`, así que
agrupan bien y no filtran datos. Para verlas con los valores hay que poner
`SQL_LOG_LEVEL=DEBUG`, y entonces salen por log:

```sql
SELECT timestamp, message FROM Log
WHERE service.name = 'microservice-users' AND message LIKE '%select%'
SINCE 30 minutes ago LIMIT 50
```

### Contexto que cruza servicios

Peticiones a users que vinieron de orders, sin que users sepa nada de orders:

```sql
SELECT count(*) FROM Span
WHERE service.name = 'microservice-users'
  AND baggage.caller.service = 'poc-microservice-orders'
FACET name
SINCE 3 hours ago
```

### Una petición completa, de punta a punta

```sql
SELECT timestamp, service.name, name, duration.ms
FROM Span WHERE trace.id = 'PEGA_EL_TRACE_ID'
SINCE 1 day ago LIMIT 100
```

```sql
SELECT timestamp, service.name, level, message
FROM Log WHERE trace.id = 'PEGA_EL_TRACE_ID'
SINCE 1 day ago LIMIT 100
```

El `trace.id` lo devuelve la cabecera `X-Trace-Id` de cualquier respuesta, y la
colección de Postman lo imprime ya en la consola.

### Mejoras a tu página Microservices

**`Error rate (%) by service` es un billboard con `TIMESERIES`.** Un billboard
muestra un número; el `TIMESERIES` no le aporta nada y confunde. O lo pasas a
`viz.line`, o le quitas el `TIMESERIES`.

**`50 / P90 / P95 per service`** dice 50 en el título pero calcula p50. Es
`p50 / p90 / p95`.

**`percentile(http.server.request.duration, ...)` devuelve segundos, no
milisegundos**, porque la convención estable de OTel usa segundos. Las etiquetas
dicen `(ms)`. O multiplicas por 1000, o corriges la etiqueta:

```sql
SELECT percentile(http.server.request.duration, 95) * 1000 AS 'p95 ms'
FROM Metric
WHERE metricName = 'http.server.request.duration' AND url.scheme = 'https'
FACET service.name, http.route
SINCE 3 hours ago LIMIT 15
```

**El filtro `url.scheme = 'https'` está bien**, pero conviene saber por qué está:
excluye las sondas internas de App Service, que van por http. Si algún día
mides tráfico http legítimo, ese filtro lo oculta.

---

## 3. Infra

Tu página Infra está vacía. Estas consultas son nuevas.

### Salud del colector — el vigilante del vigilante

Si el colector se atasca, **pierdes telemetría sin ninguna señal** salvo que
mires esto. Ya lo sufrimos: estuvo sin arrancar y el síntoma fue latencia, no un
error.

```sql
SELECT
  latest(otelcol_exporter_sent_spans) AS 'Spans sent',
  latest(otelcol_exporter_send_failed_spans) AS 'Spans failed',
  latest(otelcol_exporter_sent_log_records) AS 'Logs sent',
  latest(otelcol_exporter_send_failed_log_records) AS 'Logs failed',
  latest(otelcol_exporter_sent_metric_points) AS 'Metric points sent'
FROM Metric WHERE service.name = 'otel-collector'
SINCE 1 hour ago
```

Datos rechazados o descartados. **Cualquier valor distinto de cero aquí significa
telemetría perdida:**

```sql
SELECT
  latest(otelcol_processor_refused_spans) AS 'Spans refused',
  latest(otelcol_processor_dropped_spans) AS 'Spans dropped',
  latest(otelcol_processor_refused_log_records) AS 'Logs refused',
  latest(otelcol_processor_refused_metric_points) AS 'Metric points refused'
FROM Metric WHERE service.name = 'otel-collector'
TIMESERIES 5 minutes SINCE 6 hours ago
```

Memoria contra el límite del `memory_limiter`, que está en **400 MiB**:

```sql
SELECT latest(otelcol_process_memory_rss) / 1e6 AS 'RSS MB'
FROM Metric WHERE service.name = 'otel-collector'
TIMESERIES 1 minute SINCE 3 hours ago
```

Lo que entra por cada receptor. Sirve para ver de un golpe si una vía se ha
quedado muda:

```sql
SELECT latest(otelcol_receiver_accepted_log_records) AS 'Logs accepted'
FROM Metric WHERE service.name = 'otel-collector'
FACET receiver
TIMESERIES 5 minutes SINCE 6 hours ago
```

### Redis

Los nombres de estas métricas **están verificados**: se obtuvieron ejecutando el
receptor `redis` del colector contra un Redis real y leyendo lo que emite.

```sql
SELECT
  latest(redis.clients.connected) AS 'Connected clients',
  latest(redis.memory.used) / 1e6 AS 'Memory MB',
  latest(redis.commands.processed) AS 'Commands processed',
  latest(redis.keyspace.hits) AS 'Keyspace hits',
  latest(redis.keyspace.misses) AS 'Keyspace misses',
  latest(redis.uptime) AS 'Uptime s'
FROM Metric WHERE service.name = 'tyk-redis'
SINCE 1 hour ago
```

Redis es donde viven las credenciales de consumidor, y **no tiene persistencia**.
Esta consulta detecta que se ha vaciado, que es la causa de un 401 en todas las
APIs a la vez:

```sql
SELECT latest(redis.db.keys) AS 'Keys in Redis'
FROM Metric WHERE service.name = 'tyk-redis'
TIMESERIES 1 minute SINCE 6 hours ago
```

> **`redis.db.keys` solo existe cuando hay claves.** Comprobado: con la base de
> datos vacía el receptor no emite `redis.db.keys`, `redis.db.expires` ni
> `redis.db.avg_ttl` en absoluto. Así que en esta gráfica **una réplica nueva no
> se ve como una caída a cero, se ve como una interrupción de la serie**. Para
> alertar hay que usar ausencia de señal, no un umbral.

El `redis.uptime` es el detector más directo de réplica nueva: si se reinicia a un
valor bajo, el contenedor arrancó de cero y las credenciales se perdieron.

```sql
SELECT latest(redis.uptime) AS 'Uptime s'
FROM Metric WHERE service.name = 'tyk-redis'
TIMESERIES 1 minute SINCE 12 hours ago
```

Métricas disponibles, la lista completa tal como la emite el receptor:

`redis.clients.blocked`, `redis.clients.connected`,
`redis.clients.max_input_buffer`, `redis.clients.max_output_buffer`,
`redis.commands`, `redis.commands.processed`, `redis.connections.received`,
`redis.connections.rejected`, `redis.cpu.time`, `redis.db.avg_ttl`,
`redis.db.expires`, `redis.db.keys`, `redis.keys.evicted`, `redis.keys.expired`,
`redis.keyspace.hits`, `redis.keyspace.misses`, `redis.latest_fork`,
`redis.memory.fragmentation_ratio`, `redis.memory.lua`, `redis.memory.peak`,
`redis.memory.rss`, `redis.memory.used`, `redis.net.input`, `redis.net.output`,
`redis.rdb.changes_since_last_save`,
`redis.replication.backlog_first_byte_offset`, `redis.replication.offset`,
`redis.slaves.connected`, `redis.uptime`

### Tyk Pump

```sql
SELECT count(*) FROM Metric
WHERE service.name = 'tyk-pump'
FACET metricName
SINCE 1 hour ago LIMIT 30
```

### Base de datos SQL y App Service

Estas métricas llegan por la **integración nativa de New Relic con Azure**, no por
el colector, así que los nombres los pone New Relic y **no los he verificado**.
Descúbrelos primero y luego construye la consulta:

```sql
-- Qué métricas de Azure hay en la cuenta
SELECT uniques(metricName, 200) FROM Metric
WHERE metricName LIKE '%sql%' OR metricName LIKE '%azure%'
SINCE 1 day ago
```

```sql
-- Qué entidades de Azure están reportando
SELECT uniques(entity.name, 100) FROM Metric
WHERE cloud.provider = 'azure' OR entity.type LIKE '%AZURE%'
SINCE 1 day ago
```

Con los nombres reales, el patrón para DTU y conexiones sería:

```sql
SELECT average(NOMBRE_METRICA_DTU) AS 'DTU %'
FROM Metric WHERE entity.name = 'sqldb-users'
TIMESERIES 5 minutes SINCE 6 hours ago
```

Mientras tanto, la salud de la base de datos **sí está disponible** desde la
propia aplicación, y es más fiable que una métrica de plataforma porque mide el
camino real que recorre el servicio:

```sql
SELECT
  latest(health.database.status) AS 'Status',
  average(health.database.duration_ms) AS 'Avg latency ms',
  max(health.database.duration_ms) AS 'Worst ms'
FROM Span WHERE health.database.status IS NOT NULL
FACET service.name
TIMESERIES 5 minutes SINCE 6 hours ago
```

### Salud de la cadena completa

```sql
SELECT count(*) FROM Span
WHERE health.overall IS NOT NULL
FACET service.name, health.overall
TIMESERIES 5 minutes SINCE 6 hours ago
```

```sql
SELECT
  latest(health.external_api_users.status) AS 'orders -> tyk -> users',
  average(health.external_api_users.duration_ms) AS 'Latency ms'
FROM Span WHERE service.name = 'microservice-orders'
  AND health.external_api_users.status IS NOT NULL
TIMESERIES 5 minutes SINCE 6 hours ago
```

### Qué componentes están reportando

Un solo widget que revela un componente caído por ausencia de datos:

```sql
SELECT count(*) FROM Metric
WHERE service.namespace = 'poc-observability'
FACET service.name
TIMESERIES 5 minutes SINCE 6 hours ago
```

Deberían aparecer cinco series: `tyk-gateway`, `tyk-redis`, `tyk-pump`,
`otel-collector` y los dos microservicios. **Una serie que desaparece es un
componente que dejó de emitir**, y eso no lo detecta ninguna alerta sobre
errores, porque no hay errores: no hay nada.

---

## 4. Para la alerta de 503

La condición que pedías, ya escrita contra los atributos reales. En el gateway:

```sql
SELECT count(*) FROM Metric
WHERE service.name = 'tyk-gateway' AND span.kind = 'SPAN_KIND_SERVER'
  AND http.status_code = 503
FACET tyk.api.name
```

Y en los microservicios, con la causa concreta en lugar de un 503 genérico:

```sql
SELECT count(*) FROM Log
WHERE error.code = 'USERS_SERVICE_UNAVAILABLE'
FACET service.name, error.dependency
```

La segunda es mejor para alertar: un 503 puede tener varias causas, pero
`USERS_SERVICE_UNAVAILABLE` con `error.dependency = tyk-gateway` dice exactamente
qué salto se rompió. Configúrala con una ventana de 5 minutos y umbral por encima
de lo que produzca el tráfico normal.

---

## 5. Trampas que ya nos han costado tiempo

**`percentile()` sobre `http.server.request.duration` devuelve SEGUNDOS.** La
convención estable de OTel usa segundos; la antigua usaba milisegundos. Multiplica
por 1000 o etiqueta bien.

**`span.kind` se escribe distinto en `Metric` y en `Span`.** En las métricas de
spanmetrics es `'SPAN_KIND_SERVER'`; consultando `Span` directamente es
`'server'`. Mezclarlos devuelve vacío sin error.

**Una faceta sin datos no aparece.** No es lo mismo "cero errores" que "el
servicio no reporta". Para lo segundo hace falta la consulta de la sección 3.

**`http.target` no existe en las métricas del gateway.** Se retiró por
cardinalidad. Usa **`tyk.route`**, que es la ruta ya agrupada, o vete a `Span` si
necesitas la ruta con los identificadores.

**`http.route` no existe en el gateway, con ningún nombre.** Medido sobre Tyk
v5.12.0. Estuvo declarada en las dimensiones de `spanmetrics` y en el filtro de
spans de salud, y en los dos sitios no hacía nada. Si ves un `FACET` vacío en el
gateway, esto es lo primero que hay que descartar.

**El status del span no sirve para contar 4xx en el gateway.** Tyk marca `Error`
en los 5xx pero deja `Unset` en los 4xx, los 401 incluidos. Filtra siempre por
`http.status_code`.

**Sin `span.kind = 'SPAN_KIND_SERVER'` los totales del gateway salen inflados.**
`detailed_tracing` hace que Tyk emita spans internos de middleware y
`spanmetrics` también los convierte en métricas.

**Una petición que no encaja con ninguna API es invisible.** No genera span, así
que no hay métrica ni traza. Solo se ve en los logs de acceso, y hoy con
`track_404_logs: false` tampoco.

**El gateway y los microservicios no comparten nombres de atributo.** Convención
antigua contra estable. Ver la tabla de la sección 0; para cruzar capas, usa
`trace.id`.

**Los atributos de negocio están en `Span` Y en `Log`,** pero `duration.ms` solo
en `Span` y `message` solo en `Log`. Elige el evento según lo que necesites
medir.
