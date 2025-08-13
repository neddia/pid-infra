#!/usr/bin/env bash
set -euo pipefail
START_TS=$(date +%s%3N || date +%s000)
RESULTS=(); FAILS=0; WARNS=0
JSON=/var/lib/pid-edge/selftest.json
mkdir -p /var/lib/pid-edge

# Load env
set +u
[ -f /etc/pid/site.env ] && . /etc/pid/site.env
[ -f /etc/pid/secrets.env ] && . /etc/pid/secrets.env
[ -f /etc/pid/secret-admin.env ] && . /etc/pid/secret-admin.env
set -u

SITE="${SITE_ID:-$(hostname)}"
INFLUX_URL="${INFLUX_URL:-http://127.0.0.1:8086}"
INFLUX_ORG="${INFLUX_ORG:-pid}"
INFLUX_BUCKET="${INFLUX_BUCKET:-metrics}"

add(){ local lvl="$1" name="$2" ok="$3" msg="$4"; RESULTS+=("{\"level\":\"$lvl\",\"name\":\"$name\",\"ok\":$ok,\"message\":$(jq -Rn --arg s "$msg" '$s')}"); [ "$lvl" = fail ] && FAILS=$((FAILS+1)) || { [ "$lvl" = warn ] && WARNS=$((WARNS+1)); }; [ "$ok" -eq 1 ] && echo "✓ $name: $msg" || echo "✗ $name: $msg"; }

# Tailscale
if command -v tailscale >/dev/null 2>&1; then
  tailscale status --json 2>/dev/null | jq -e '.BackendState=="Running"' >/dev/null 2>&1 && add pass tailscale 1 "backend running" || add fail tailscale 0 "not running"
else add warn tailscale 0 "not installed"; fi

# UFW SSH rules
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  (ufw status | grep -E "tailscale0.*ALLOW.*22" >/dev/null) && (ufw status | grep -E "22/tcp.*DENY" >/dev/null) && add pass firewall_ssh 1 "SSH allowed on tailnet, denied public" || add warn firewall_ssh 0 "rules unexpected"
else add warn firewall 0 "UFW inactive/missing"; fi

# Docker stack
need=(influxdb chirpstack chirpstack-postgres mosquitto chirpstack-rest)
if command -v docker >/dev/null 2>&1; then
  miss=(); for c in "${need[@]}"; do docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null | grep -q true || miss+=("$c"); done
  [ ${#miss[@]} -eq 0 ] && add pass docker_stack 1 "all running" || add fail docker_stack 0 "stopped: ${miss[*]}"
else add fail docker 0 "not installed"; fi

# MQTT port
timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/1883' 2>/dev/null && exec 3<&- 3>&- && add pass mqtt_port 1 "1883 open" || add fail mqtt_port 0 "1883 unreachable"

# Influx health + write/read
if curl -fsS "${INFLUX_URL}/health" >/dev/null 2>&1; then
  add pass influx_health 1 "ok"
  if [ -n "${INFLUX_TOKEN:-}" ]; then
    TS=$(date +%s); LINE="selftest,site_id=${SITE},component=influx_write value=1 ${TS}"
    if docker exec influxdb influx write -o "${INFLUX_ORG}" -b "${INFLUX_BUCKET}" -t "${INFLUX_TOKEN}" --precision s "${LINE}" 2>/dev/null; then
      if [ -n "${INFLUX_ADMIN_TOKEN:-}" ]; then
        Q='from(bucket: BUCKET) |> range(start: -5m) |> filter(fn: (r) => r._measurement == "selftest" and r.component == "influx_write") |> last()'
        Q=${Q//BUCKET/${INFLUX_BUCKET}}
        docker exec influxdb influx query -o "${INFLUX_ORG}" -t "${INFLUX_ADMIN_TOKEN}" --raw "$Q" | grep -q "selftest" && add pass influx_write_read 1 "round-trip ok" || add fail influx_write_read 0 "query none"
      else add warn influx_write_read 0 "no admin token to verify read"; fi
    else add fail influx_write 0 "write failed"; fi
  else add fail influx_token 0 "INFLUX_TOKEN missing"; fi
else add fail influx_health 0 "not healthy"; fi

# ChirpStack tenant & REST
if [ -n "${CHIRPSTACK_ADMIN_API_KEY:-}" ]; then
  curl -fsS -H "Authorization: Bearer ${CHIRPSTACK_ADMIN_API_KEY}" -H "Grpc-Metadata-Authorization: Bearer ${CHIRPSTACK_ADMIN_API_KEY}" "http://127.0.0.1:8090/api/internal/info" >/dev/null 2>&1 && add pass chirpstack_rest 1 "ok" || add fail chirpstack_rest 0 "auth/rest fail"
  TEN_JSON=$(curl -fsS -H "Authorization: Bearer ${CHIRPSTACK_ADMIN_API_KEY}" -H "Grpc-Metadata-Authorization: Bearer ${CHIRPSTACK_ADMIN_API_KEY}" "http://127.0.0.1:8090/api/tenants?limit=1000" 2>/dev/null || true)
  echo "$TEN_JSON" | jq -e ".result[]? | select(.name==\"${SITE}\")" >/dev/null 2>&1 && add pass chirpstack_tenant 1 "tenant ${SITE}" || add fail chirpstack_tenant 0 "tenant missing"
else add fail chirpstack_api_key 0 "missing admin key"; fi

# Units/timers
CURR="/opt/pid-app/current"
for u in pid-poller.service pid-config-server.service; do
  if systemctl is-enabled "$u" >/dev/null 2>&1; then
    if [ -e "$CURR" ] && systemctl is-active "$u" >/dev/null 2>&1; then add pass "$u" 1 "enabled & active"; else add warn "$u" 0 "enabled; not active yet"; fi
  else add warn "$u" 0 "not enabled"; fi
done
systemctl is-enabled pid-edge-agent.timer >/dev/null 2>&1 && add pass edge_agent_timer 1 "enabled" || add warn edge_agent_timer 0 "not enabled"

# Secrets perms
if [ -f /etc/pid/secrets.env ]; then
  PERM=$(stat -c "%a" /etc/pid/secrets.env); GRP=$(stat -c "%G" /etc/pid/secrets.env)
  [ "$PERM" = "640" ] && { [ "$GRP" = "adm" ] || [ "$GRP" = "root" ]; } && add pass secrets_perms 1 "ok" || add warn secrets_perms 0 "expected 640 & adm/root"
else add fail secrets_file 0 "missing /etc/pid/secrets.env"; fi

# Emit JSON + optional summary metric
END_TS=$(date +%s%3N || date +%s000); DUR=$((END_TS-START_TS))
printf '{"site_id":%s,"timestamp":%s,"duration_ms":%s,"fails":%s,"warns":%s,"results":[%s]}\n' \
  "$(jq -Rn --arg s "$SITE" '$s')" "$END_TS" "$DUR" "$FAILS" "$WARNS" "$(IFS=,; echo "${RESULTS[*]}")" > "$JSON"
[ -n "${INFLUX_TOKEN:-}" ] && docker exec influxdb influx write -o "${INFLUX_ORG}" -b "${INFLUX_BUCKET}" -t "${INFLUX_TOKEN}" --precision s "selftest_summary,site_id=${SITE} fails=${FAILS}i,warns=${WARNS}i,duration_ms=${DUR}i $(date +%s)" >/dev/null 2>&1 || true
[ "$FAILS" -eq 0 ] || exit 1
