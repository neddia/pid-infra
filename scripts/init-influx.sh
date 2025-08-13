#!/usr/bin/env bash
set -euo pipefail
SITE_ID="${SITE_ID:-$(hostname)}"
INFLUX_URL="${INFLUX_URL:-http://127.0.0.1:8086}"
INFLUX_ORG="${INFLUX_ORG:-pid}"
INFLUX_BUCKET="${INFLUX_BUCKET:-metrics}"
SECRETS_FILE="/etc/pid/secrets.env"
ADMIN_FILE="/etc/pid/secret-admin.env"

mkdir -p /etc/pid; chmod 0750 /etc/pid
need() { command -v "$1" >/dev/null 2>&1 || { apt-get update -y; apt-get install -y "$1"; }; }
need jq; need curl

echo "[init-influx] waiting for ${INFLUX_URL}"
for i in {1..60}; do curl -fsS "${INFLUX_URL}/health" >/dev/null && break || sleep 2; done

if curl -fsS "${INFLUX_URL}/api/v2/setup" | jq -e '.allowed == true' >/dev/null; then
  echo "[init-influx] onboarding"
  INF_ADMIN_PASS="$(openssl rand -base64 24)"
  ADMIN_JSON="$(docker exec influxdb influx setup \
      --org "${INFLUX_ORG}" \
      --bucket "${INFLUX_BUCKET}" \
      --retention 0 \
      --username pidadmin \
      --password "${INF_ADMIN_PASS}" \
      --force --json)"
  ADMIN_TOKEN="$(echo "${ADMIN_JSON}" | jq -r '.auth.token')"
  install -m 0600 /dev/null "${ADMIN_FILE}"
  {
    echo "INFLUX_ADMIN_USER=pidadmin"
    echo "INFLUX_ADMIN_PASS=${INF_ADMIN_PASS}"
    echo "INFLUX_ADMIN_TOKEN=${ADMIN_TOKEN}"
  } > "${ADMIN_FILE}"
else
  if [ -f "${ADMIN_FILE}" ]; then
    ADMIN_TOKEN="$(. "${ADMIN_FILE}"; echo "${INFLUX_ADMIN_TOKEN}")"
  else
    echo "[init-influx] ERROR: already setup but ${ADMIN_FILE} missing"; exit 1
  fi
fi

# Ensure write-only token for bucket
BUCKETS_JSON="$(docker exec influxdb influx bucket list -o "${INFLUX_ORG}" --json --host "${INFLUX_URL}" --token "${ADMIN_TOKEN}")"
BUCKET_ID="$(echo "${BUCKETS_JSON}" | jq -r ".[] | select(.name==\"${INFLUX_BUCKET}\") | .id")"
[ -n "${BUCKET_ID}" ] && [ "${BUCKET_ID}" != "null" ] || { echo "[init-influx] bucket not found"; exit 1; }

if grep -q '^INFLUX_TOKEN=' "${SECRETS_FILE}" 2>/dev/null; then
  echo "[init-influx] write token already present"
else
  WRITE_JSON="$(docker exec influxdb influx auth create \
      --org "${INFLUX_ORG}" \
      --write-buckets "${BUCKET_ID}" \
      --json \
      --host "${INFLUX_URL}" \
      --token "${ADMIN_TOKEN}")"
  WRITE_TOKEN="$(echo "${WRITE_JSON}" | jq -r '.[0].token // .token')"
  install -m 0640 /dev/null "${SECRETS_FILE}"
  {
    echo "SITE_ID=${SITE_ID}"
    echo "INFLUX_URL=${INFLUX_URL}"
    echo "INFLUX_ORG=${INFLUX_ORG}"
    echo "INFLUX_BUCKET=${INFLUX_BUCKET}"
    echo "INFLUX_TOKEN=${WRITE_TOKEN}"
  } >> "${SECRETS_FILE}"
  chgrp adm "${SECRETS_FILE}" || true
  echo "[init-influx] wrote site write token"
fi
