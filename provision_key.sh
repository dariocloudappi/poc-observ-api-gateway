#!/bin/bash
set -e

source .env

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