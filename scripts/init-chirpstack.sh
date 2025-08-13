#!/usr/bin/env bash
set -euo pipefail
SITE_ID="${SITE_ID:-$(hostname)}"
CS_REST="http://127.0.0.1:8090"
SECRETS_FILE="/etc/pid/secrets.env"
ADMIN_FILE="/etc/pid/secret-admin.env"

mkdir -p /etc/pid; chmod 0750 /etc/pid
need() { command -v "$1" >/dev/null 2>&1 || { apt-get update -y; apt-get install -y "$1"; }; }
need jq; need curl

echo "[init-chirpstack] wait for chirpstack (8080) + rest (8090)"
for i in {1..60}; do
  curl -fsS "http://127.0.0.1:8080" >/dev/null && curl -fsS "${CS_REST}/" >/dev/null && break || sleep 2
done

# Admin API key
if grep -q '^CHIRPSTACK_ADMIN_API_KEY=' "${ADMIN_FILE}" 2>/dev/null; then
  CS_ADMIN_KEY="$(. "${ADMIN_FILE}"; echo "${CHIRPSTACK_ADMIN_API_KEY}")"
else
  echo "[init-chirpstack] creating admin API key via CLI"
  set +e
  RAW="$(docker exec chirpstack chirpstack create-api-key --name "pid-edge-admin-${SITE_ID}" --admin 2>/dev/null)"
  RC=$?; set -e
  [ $RC -eq 0 ] && [ -n "${RAW}" ] || { echo "[init-chirpstack] ERROR: create-api-key failed; create one in UI and put CHIRPSTACK_ADMIN_API_KEY in ${ADMIN_FILE}"; exit 1; }
  if echo "${RAW}" | jq -e . >/dev/null 2>&1; then
    CS_ADMIN_KEY="$(echo "${RAW}" | jq -r '.token // .apiKey // .key')"
  else
    CS_ADMIN_KEY="$(echo "${RAW}" | awk '{print $NF}')"
  fi
  install -m 0600 /dev/null "${ADMIN_FILE}"
  echo "CHIRPSTACK_ADMIN_API_KEY=${CS_ADMIN_KEY}" > "${ADMIN_FILE}"
fi

# Tenant for SITE_ID
TEN_LIST="$(curl -fsS -H "Authorization: Bearer ${CS_ADMIN_KEY}" -H "Grpc-Metadata-Authorization: Bearer ${CS_ADMIN_KEY}" "${CS_REST}/api/tenants?limit=1000")"
TEN_ID="$(echo "${TEN_LIST}" | jq -r ".result[]? | select(.name==\"${SITE_ID}\") | .id")"
if [ -z "${TEN_ID}" ] || [ "${TEN_ID}" = "null" ]; then
  echo "[init-chirpstack] creating tenant '${SITE_ID}'"
  TEN_JSON="$(curl -fsS -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${CS_ADMIN_KEY}" \
    -H "Grpc-Metadata-Authorization: Bearer ${CS_ADMIN_KEY}" \
    -d "{\"name\":\"${SITE_ID}\",\"description\":\"PID site ${SITE_ID}\",\"canHaveGateways\":true}" \
    "${CS_REST}/api/tenants")"
  TEN_ID="$(echo "${TEN_JSON}" | jq -r '.id // .result.id // .tenant.id')"
fi
[ -n "${TEN_ID}" ] && [ "${TEN_ID}" != "null" ] || { echo "[init-chirpstack] ERROR: tenant id missing"; exit 1; }

# Persist to secrets
install -m 0640 /dev/null "${SECRETS_FILE}"
grep -q '^CHIRPSTACK_TENANT_ID=' "${SECRETS_FILE}" 2>/dev/null || echo "CHIRPSTACK_TENANT_ID=${TEN_ID}" >> "${SECRETS_FILE}"
grep -q '^CHIRPSTACK_ADMIN_API_KEY=' "${SECRETS_FILE}" 2>/dev/null || echo "CHIRPSTACK_ADMIN_API_KEY=${CS_ADMIN_KEY}" >> "${SECRETS_FILE}"
chgrp adm "${SECRETS_FILE}" || true
echo "[init-chirpstack] wrote tenant + admin key"
