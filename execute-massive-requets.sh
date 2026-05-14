#!/bin/bash
# generate-load.sh — ejecutar ANTES de la PoC

#!/bin/bash
set -e

source .credentials.tyk.env

URL= $URL_GW_USERS
TOKEN= $BASIC_GW_USERS
COUNT=20

echo "Enviando $COUNT peticiones a $URL..."

for i in $(seq 1 $COUNT); do
(
  START_TIME=$(date +"%Y-%m-%d %H:%M:%S")

  RESPONSE=$(curl -s \
    -H "Authorization: $TOKEN" \
    -w "\nHTTP_CODE:%{http_code}\nTIME_TOTAL:%{time_total}" \
    "$URL")

  BODY=$(echo "$RESPONSE" | sed '/HTTP_CODE:/,$d')
  HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
  TIME_TOTAL=$(echo "$RESPONSE" | grep "TIME_TOTAL:" | cut -d: -f2)

  echo "=============================="
  echo "Hora ejecución : $START_TIME"
  echo "URL             : $URL"
  echo "HTTP Code       : $HTTP_CODE"
  echo "Tiempo total    : ${TIME_TOTAL}s"
  echo "Response Body:"
  echo "$BODY"
  echo "=============================="

) &
done

wait
echo "✅ $COUNT peticiones enviadas