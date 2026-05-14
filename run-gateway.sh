export $(grep -v '^#' .env | xargs) && \
docker compose down -v && \
docker compose up -d && \
echo "Waiting for Tyk to be ready..." && \
until curl -sk https://localhost/hello | grep -q "pass"; do
  echo "  → Tyk not ready, retrying in 3s..."
  sleep 3
done && \
echo "Tyk is ready, provisioning keys..." && \
bash provision_key.sh