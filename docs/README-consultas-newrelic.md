# Consultas NRQL de la PoC

Catálogo de las consultas del dashboard **Poc Observabilidad**, por página y por
widget, y de las condiciones de alerta.

Las consultas no llevan identificador de cuenta ni de entidad: al importarlas o
pegarlas en el query builder se resuelven contra la cuenta activa.

---

## 1. Página "API Gateway"

12 widgets. Todos sobre `FROM Metric`, `service.name = 'tyk-gateway'` y
`span.kind = 'SPAN_KIND_SERVER'`.

### 1.1 Total requests — `viz.billboard`

Volumen total en la ventana.

```sql
SELECT sum(`tyk.gateway.calls`) AS 'Total requests'
FROM Metric
WHERE service.name = 'tyk-gateway'
AND span.kind = 'SPAN_KIND_SERVER'
SINCE 1 hour ago
```

### 1.2 RPM — `viz.line`

Peticiones por minuto, desglosadas por API y código.

```sql
SELECT rate(sum(`tyk.gateway.calls`), 1 minute) AS 'RPM'
FROM Metric
WHERE service.name = 'tyk-gateway'
AND span.kind = 'SPAN_KIND_SERVER'
FACET tyk.api.name, http.status_code
TIMESERIES 1 minute
SINCE 1 hour ago
```

### 1.3 All responses by status code — `viz.pie`

Reparto de respuestas por API y código.

```sql
SELECT sum(`tyk.gateway.calls`) AS 'Total requests'
FROM Metric
WHERE service.name = 'tyk-gateway'
AND span.kind = 'SPAN_KIND_SERVER'
FACET tyk.api.name, http.status_code
SINCE 1 hour ago
```

### 1.4 Time series by category — `viz.line`

Evolución de 2xx, 4xx y 5xx por API.

```sql
SELECT filter(sum(`tyk.gateway.calls`), WHERE http.status_code >= 200 AND http.status_code < 300) AS '2xx',
  filter(sum(`tyk.gateway.calls`), WHERE http.status_code >= 400 AND http.status_code < 500) AS '4xx',
  filter(sum(`tyk.gateway.calls`), WHERE http.status_code >= 500) AS '5xx'
FROM Metric
WHERE service.name = 'tyk-gateway'
AND span.kind = 'SPAN_KIND_SERVER'
FACET tyk.api.name
TIMESERIES 1 minute
SINCE 1 hour ago
```

### 1.5 API calls — `viz.area`

Llamadas por API a lo largo del tiempo.

```sql
SELECT sum(`tyk.gateway.calls`) AS 'Calls per API'
FROM Metric
WHERE service.name = 'tyk-gateway'
AND span.kind = 'SPAN_KIND_SERVER'
FACET tyk.api.name
TIMESERIES 1 minute
SINCE 1 hour ago
```

### 1.6 Average latency per API — `viz.area`

```sql
SELECT average(`tyk.gateway.duration`) AS 'Avg ms',
       percentile(`tyk.gateway.duration`, 95) AS 'P95 ms',
       percentile(`tyk.gateway.duration`, 99) AS 'P99 ms'
FROM Metric
WHERE service.name = 'tyk-gateway'
AND span.kind = 'SPAN_KIND_SERVER'
FACET tyk.api.name
TIMESERIES 1 minute
SINCE 1 hour ago
```

### 1.7 Rate over time — `viz.line`

```sql
SELECT rate(sum(`tyk.gateway.calls`), 1 minute) AS 'RPM'
FROM Metric
WHERE service.name = 'tyk-gateway'
AND span.kind = 'SPAN_KIND_SERVER'
FACET tyk.api.name, http.status_code
TIMESERIES 1 minute
SINCE 1 hour ago
```

### 1.8 Top API Usage — `viz.table`

APIs más consumidas.

```sql
SELECT sum(`tyk.gateway.calls`) AS 'Requests in period'
FROM Metric
WHERE service.name = 'tyk-gateway' AND span.kind = 'SPAN_KIND_SERVER'
FACET tyk.api.name AS 'Name API'
SINCE 1 day ago
LIMIT 20
```

### 1.9 Top APIs Lowest Usage — `viz.table`

APIs menos consumidas.

```sql
SELECT sum(`tyk.gateway.calls`) AS 'Requests in period'
FROM Metric
WHERE service.name = 'tyk-gateway' AND span.kind = 'SPAN_KIND_SERVER'
FACET tyk.api.name AS 'Name API'
SINCE 1 day ago
LIMIT MAX
```

### 1.10 Top Resources — `viz.pie`

Recursos más consumidos, por método y ruta agrupada.

```sql
SELECT sum(`tyk.gateway.calls`) AS 'Requests in period'
FROM Metric
WHERE service.name = 'tyk-gateway' AND span.kind = 'SPAN_KIND_SERVER'
  AND tyk.route IS NOT NULL
FACET http.method, tyk.route
SINCE 6 hours ago
LIMIT 25
```

### 1.11 Top Errors API — `viz.pie`

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

### 1.12 Latency by API — `viz.table`

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

---

## 2. Página "Microservices"

11 widgets, todos sobre `FROM Metric` con
`metricName = 'http.server.request.duration'` y `url.scheme = 'https'`.

### 2.1 Requests per minute — `viz.line`

```sql
SELECT rate(count(*), 1 minute) AS 'RPM'
FROM Metric
WHERE metricName = 'http.server.request.duration'
AND `url.scheme` = 'https'
FACET service.name
TIMESERIES AUTO
SINCE 3 hours ago
```

### 2.2 Total RPM compared with yesterday — `viz.billboard`

```sql
SELECT rate(count(*), 1 minute) AS 'RPM'
FROM Metric
WHERE metricName = 'http.server.request.duration'
AND `url.scheme` = 'https'
FACET service.name
SINCE 3 hours ago
COMPARE WITH 1 day ago
```

### 2.3 Total number of requests in the window by service — `viz.pie`

```sql
SELECT count(*) AS 'Total requests'
FROM Metric
WHERE metricName = 'http.server.request.duration'
AND `url.scheme` = 'https'
FACET service.name
SINCE 3 hours ago
```

### 2.4 Trend in requests by HTTP method — `viz.line`

```sql
SELECT rate(count(*), 1 minute) AS 'RPM'
FROM Metric
WHERE metricName = 'http.server.request.duration'
AND `url.scheme` = 'https'
FACET `http.request.method`
TIMESERIES AUTO
SINCE 3 hours ago
```

### 2.5 Top endpoints by volume — `viz.bar`

```sql
SELECT count(*) AS 'Requests in period'
FROM Metric
WHERE metricName = 'http.server.request.duration'
AND `url.scheme` = 'https'
AND `http.route` IS NOT NULL
FACET service.name, `http.request.method`, `http.route`
LIMIT 15
SINCE 3 hours ago
```

### 2.6 Breakdown of status codes by service — `viz.pie`

```sql
SELECT count(*) AS 'Requests in period'
FROM Metric
WHERE metricName = 'http.server.request.duration'
AND `url.scheme` = 'https'
AND `http.response.status_code` IS NOT NULL
FACET service.name, `http.response.status_code`
SINCE 3 hours ago
LIMIT 20
```

### 2.7 Error rate (%) by service — `viz.billboard`

```sql
SELECT
  filter(count(*), WHERE `http.response.status_code` >= 400
    AND `http.response.status_code` < 500) / count(*) * 100 AS '4xx %',
  filter(count(*), WHERE `http.response.status_code` >= 500)
    / count(*) * 100 AS '5xx %'
FROM Metric
WHERE metricName = 'http.server.request.duration'
AND `url.scheme` = 'https'
FACET service.name
TIMESERIES AUTO
SINCE 3 hours ago
```

### 2.8 Errors broken down by service — `viz.table`

```sql
SELECT count(*) AS 'Requests in period',
  filter(count(*), WHERE `http.response.status_code` >= 400
    AND `http.response.status_code` < 500) AS '4xx',
  filter(count(*), WHERE `http.response.status_code` >= 500) AS '5xx',
  filter(count(*), WHERE `http.response.status_code` = 503) AS '503',
  filter(count(*), WHERE `http.response.status_code` = 429) AS '429',
  filter(count(*), WHERE `http.response.status_code` = 401) AS '401'
FROM Metric
WHERE metricName = 'http.server.request.duration'
AND `url.scheme` = 'https'
FACET service.name
SINCE 3 hours ago
```

### 2.9 Errors by service and endpoint — `viz.bar`

```sql
SELECT filter(count(*), WHERE `http.response.status_code` >= 400) AS 'Error count'
FROM Metric
WHERE metricName = 'http.server.request.duration'
AND `url.scheme` = 'https'
AND `http.route` IS NOT NULL
FACET service.name, `http.route`, `http.response.status_code`
LIMIT 20
SINCE 3 hours ago
```

### 2.10 P50 / P90 / P95 per service — `viz.line`

```sql
SELECT
  percentile(http.server.request.duration, 50) AS 'p50 (ms)',
  percentile(http.server.request.duration, 90) AS 'p90 (ms)',
  percentile(http.server.request.duration, 95) AS 'p95 (ms)'
FROM Metric
WHERE metricName = 'http.server.request.duration'
AND `url.scheme` = 'https'
FACET service.name
TIMESERIES AUTO
SINCE 3 hours ago
```

### 2.11 Slowest endpoints (90th percentile) — `viz.table`

```sql
SELECT percentile(http.server.request.duration, 90) AS 'p90 (ms)'
FROM Metric
WHERE metricName = 'http.server.request.duration'
AND `url.scheme` = 'https'
AND `http.route` IS NOT NULL
FACET service.name, `http.route`
LIMIT 15
SINCE 3 hours ago
```

---

## 3. Página "Infra"

8 widgets.

### 3.1 OTEL Collector — `viz.table`

```sql
SELECT
  latest(otelcol_exporter_sent_spans) AS 'Spans sent',
  latest(otelcol_exporter_send_failed_spans) AS 'Spans failed',
  latest(otelcol_exporter_sent_log_records) AS 'Logs sent',
  latest(otelcol_exporter_send_failed_log_records) AS 'Logs failed',
  latest(otelcol_exporter_sent_metric_points) AS 'Metric points sent'
FROM Metric WHERE service.name = 'otel-collector'
SINCE 3 hour ago
```

### 3.2 OTEL Process Memory — `viz.line`

```sql
SELECT latest(otelcol_process_memory_rss) / 1e6 AS 'RSS MB'
FROM Metric WHERE service.name = 'otel-collector'
TIMESERIES 1 minute SINCE 6 hours ago
```

### 3.3 Tyk Redis — `viz.billboard`

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

### 3.4 SQL Database Connections by Instance — `viz.line`

```sql
SELECT average(newrelic.goldenmetrics.infra.azuresqldatabase.successfulConnections) AS 'Connections OK',
       average(newrelic.goldenmetrics.infra.azuresqldatabase.failedConnections) AS 'Failed Connections'
FROM Metric WHERE entity.name IN ('sqldb-users','sqldb-orders')
FACET entity.name
TIMESERIES 5 minutes SINCE 6 hours ago
```

### 3.5 Container Apps - CPU/Memory/Replicas — `viz.line`

```sql
SELECT
  average(azure.app.containerapps.CpuPercentage) AS 'CPU %',
  average(azure.app.containerapps.MemoryPercentage) AS 'Memory %',
  latest(azure.app.containerapps.Replicas) AS 'Replicas'
FROM Metric WHERE entity.name = 'ca-tykpoc-gw'
TIMESERIES 5 minutes SINCE 6 hours ago
```

### 3.6 Container Apps - Response Time — `viz.stacked-bar`

```sql
SELECT average(azure.app.containerapps.ResponseTime) AS 'Response time ms'
FROM Metric WHERE entity.name = 'ca-tykpoc-gw'
TIMESERIES 5 minutes SINCE 6 hours ago
```

### 3.7 App Service Plans - CPU & Memory by Plan — `viz.line`

```sql
SELECT
  average(azure.web.serverfarms.CpuPercentage) AS 'CPU %',
  average(azure.web.serverfarms.MemoryPercentage) AS 'Memory %'
FROM Metric WHERE entity.name IN ('plan-usersvc','plan-ordersvc')
FACET entity.name
TIMESERIES 5 minutes SINCE 6 hours ago
```

### 3.8 Max CPU Plan Services — `viz.line`

```sql
SELECT max(azure.web.serverfarms.CpuPercentage) AS 'CPU % (peak)'
FROM Metric WHERE entity.name IN ('plan-usersvc','plan-ordersvc')
FACET entity.name
TIMESERIES 5 minutes SINCE 6 hours ago
```

---

## 4. Alertas

Objetivo: detectar cuando una API del gateway acumula muchos 503 en un intervalo
corto. El ejemplo de referencia es **100 respuestas 503 en 5 minutos**.

Las dos fuentes posibles y lo que implica cada una:

| Fuente | Retardo hasta New Relic | Depende de |
| --- | --- | --- |
| `Metric`, `tyk.gateway.calls` | hasta 90 s: `metrics_flush_interval` 60 s más `batch/metrics` 30 s | las 4 dimensiones declaradas en `spanmetrics` |
| `Span` | unos 5 s: `batch/traces` | que no haya muestreo de spans |

Hoy no hay muestreo: los dos agentes Java usan `parentbased_always_on` y el
colector no declara ningún sampler. Si se activara un muestreo, la version sobre
`Span` contaría de menos sin avisar y la de `Metric` seguiría siendo exacta.

### 4.1 Muchos 503 por API en el gateway

Una señal independiente por API.

```sql
SELECT filter(sum(`tyk.gateway.calls`), WHERE http.status_code = 503) AS 'Error count'
FROM Metric
WHERE service.name = 'tyk-gateway'
  AND span.kind = 'SPAN_KIND_SERVER'
FACET tyk.api.name
```

El filtro de 503 va dentro de `filter()` y no en el `WHERE`. Con el 503 en el
`WHERE`, la consulta no devuelve ningún dato mientras no haya errores, y una
condición sin datos no avanza su ventana de agregación con el método Event flow.
Dentro de `filter()`, la serie existe siempre que la API reciba tráfico y vale 0
cuando no hay 503, que es lo que una condición necesita para evaluarse.

`span.kind = 'SPAN_KIND_SERVER'` es obligatorio: `spanmetrics` convierte en
métrica todos los spans, incluido el client del gateway hacia el upstream, que
lleva el mismo 503. Sin él cada petición cuenta dos veces y el umbral de 100 se
alcanza con 50 peticiones reales.

### 4.2 La misma condición sobre spans

Alternativa con menos retardo y con acceso a atributos que no son dimensiones de
`spanmetrics`, como `http.target`.

```sql
SELECT filter(count(*), WHERE http.status_code = 503) AS 'Error count'
FROM Span
WHERE service.name = 'tyk-gateway'
  AND span.kind = 'server'
FACET tyk.api.name
```

En `Span` el valor de `span.kind` es `server`; en `Metric`, `SPAN_KIND_SERVER`.

Ninguna de las dos consultas usa `http.response.status_code`: Tyk 5.12 emite la
convención antigua y nunca produce ese atributo. Ese otro nombre solo hace falta
cuando la consulta abarca también los microservicios, que llevan
`OTEL_SEMCONV_STABILITY_OPT_IN=http`.

### 4.3 Restringida a una API concreta

```sql
SELECT filter(sum(`tyk.gateway.calls`), WHERE http.status_code = 503) AS 'Error count'
FROM Metric
WHERE service.name = 'tyk-gateway'
  AND span.kind = 'SPAN_KIND_SERVER'
  AND tyk.api.name = 'api-orders'
```

### 4.4 Excluir los errores provocados

Los 503 de `/force-errors` llegan al gateway como respuestas del upstream. La
marca `error.forced` solo existe en los spans del microservicio, no en los del
gateway, de modo que aquí hay que filtrar por la ruta.

Sobre métricas, con la dimensión `tyk.route`:

```sql
SELECT filter(sum(`tyk.gateway.calls`),
              WHERE http.status_code = 503
                AND tyk.route NOT LIKE '%force-errors%') AS 'Error count'
FROM Metric
WHERE service.name = 'tyk-gateway'
  AND span.kind = 'SPAN_KIND_SERVER'
FACET tyk.api.name
```

Sobre spans, con `http.target`:

```sql
SELECT filter(count(*),
              WHERE http.status_code = 503
                AND http.target NOT LIKE '%force-errors%') AS 'Error count'
FROM Span
WHERE service.name = 'tyk-gateway'
  AND span.kind = 'server'
FACET tyk.api.name
```

Con cualquiera de las dos activas, el script de 4.7 deja de disparar la alerta.

### 4.5 Comprobación previa — NO usar en la condición

Sirve para ver el volumen por ventana antes de fijar el umbral, y se ejecuta en el
query builder.

**No vale como consulta de la condición.** Una condición de alerta rechaza
`TIMESERIES`, `SINCE`, `UNTIL`, `COMPARE WITH` y `LIMIT`, y devuelve
"Query contains disallowed components". Para la condición hay que usar 4.1, 4.2 o
4.3, que no llevan ninguno de esos elementos.

```sql
SELECT filter(sum(`tyk.gateway.calls`), WHERE http.status_code = 503) AS 'Error count'
FROM Metric
WHERE service.name = 'tyk-gateway'
  AND span.kind = 'SPAN_KIND_SERVER'
FACET tyk.api.name
TIMESERIES 5 minutes
SINCE 6 hours ago
```

### 4.6 Parámetros de la condición

El intervalo y el umbral no van en el NRQL, van en la condición. Hay dos perfiles
según lo que se quiera: que la alerta salte rapido en una demostracion, o que
reproduzca el requisito de 100 errores en 5 minutos.

#### Perfil A: demostración rápida

Detección en torno a **90 segundos** desde que se lanza el script.

**Fine-tune your signal**

| Campo | Valor |
| --- | --- |
| Consulta | la de 4.2, sobre `Span` |
| Window duration | `1` minutes |
| Use sliding window aggregation | desactivado |
| Streaming method | `Event timer` |
| Timer | `30` seconds |
| Fill data gaps with | `None` |

**Set condition thresholds**

| Campo | Valor |
| --- | --- |
| Tipo | Static |
| Severity level | Critical |
| When a query returns a value | `above` `49` `for at least` `1` `minutes` |

Con `--requests 120`, el peor reparto posible de la ráfaga entre dos ventanas de
un minuto deja unas 60 peticiones en cada una, por encima de 49 en las dos: la
alerta salta aunque la ráfaga caiga a caballo de un cambio de minuto.

#### Perfil B: 100 errores en 5 minutos

Detección en torno a **7 minutos**, el requisito literal.

**Fine-tune your signal**

| Campo | Valor |
| --- | --- |
| Consulta | la de 4.1, sobre `Metric` |
| Window duration | `5` minutes |
| Use sliding window aggregation | desactivado |
| Streaming method | `Event timer` |
| Timer | `120` seconds |
| Fill data gaps with | `None` |

**Set condition thresholds**

| Campo | Valor |
| --- | --- |
| Tipo | Static |
| Severity level | Critical |
| When a query returns a value | `above` `99` `for at least` `5` `minutes` |

Las ventanas están alineadas al reloj, no empiezan cuando se lanza el script. Una
ráfaga lanzada en los últimos segundos de un intervalo se reparte entre dos
ventanas y ninguna de las dos llega a 100.

#### Por qué estos valores

`above 99` y no `above 100`: el umbral de New Relic es estrictamente mayor, de
modo que `above 100` empieza a disparar en 101. Si el desplegable ofrece
`above or equals`, `100` se lee mejor y significa lo mismo.

`for at least` dividido entre `Window duration` es el número de ventanas
consecutivas que deben superar el umbral. Con los dos valores iguales basta una
ventana.

`Event timer` y no `Event flow`: Event flow cierra cada ventana con las marcas de
tiempo de los datos que van llegando, y necesita al menos un dato por ventana. En
una PoC no hay carga sostenida, hay minutos enteros sin ninguna petición, de modo
que la ventana no avanzaría y la evaluación se quedaría esperando. Event timer
cierra la ventana con un temporizador de reloj, lleguen datos o no.

El `Timer` debe superar el retardo del pipeline: unos 5 segundos con `Span`, hasta
90 con `Metric`.

`Use sliding window aggregation` desactivado: con ventanas solapadas la misma
ráfaga se contaría en varias ventanas y la condición se dispararía repetidas
veces por un único incidente.

`Fill data gaps with None`: un hueco significa que la API no recibió tráfico, y es
información real. La opcion `Last known value` mantendría el último recuento en
las ventanas vacias y dejaria el incidente abierto indefinidamente.

Cada valor de `tyk.api.name` es una señal independiente con su propio umbral: los
eventos se cuentan por API, no en total entre todas.

#### Línea temporal del perfil A

| Momento | Qué ocurre |
| --- | --- |
| 15:00:10 | el script lanza las 120 peticiones, todas responden 503 |
| 15:01:00 | se cierra la ventana 15:00:00 - 15:01:00 |
| 15:01:30 | expira el Timer de 30 s y New Relic evalúa: 120 > 49 |
| 15:01:30 | se abre el incidente |

El dashboard muestra los 503 en segundos, pero la alerta espera a que la ventana
se cierre. No es un fallo de la condición.

### 4.7 Cómo provocarla

Cada petición produce una respuesta 503 del gateway, de modo que el número de
peticiones es el numero de eventos que ve la alerta.

```bash
./scripts/force-errors.sh --api orders --status 503 --requests 120 --yes
```

El script lanza todas las peticiones de una tanda en paralelo. Si 120 conexiones
simultáneas saturan el plan de App Service, aparecen respuestas 000 en el resumen
del script y esas no llegan a generar telemetría. En ese caso, tres tandas dentro
de la misma ventana de 5 minutos:

```bash
for i in 1 2 3; do
  ./scripts/force-errors.sh --api orders --status 503 --requests 40 --yes
done
```

La comprobación previa del script usa el código 400, no el 503, así que no suma
al recuento de la alerta.
