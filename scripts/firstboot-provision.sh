#!/usr/bin/env bash
set -euo pipefail
# Log to both journal and a file
exec > >(tee -a /var/log/firstboot.log) 2>&1
trap 'echo "[firstboot] ERROR at line $LINENO (exit $?)"' ERR
export DEBIAN_FRONTEND=noninteractive

# Feature flags to speed dev
: "${SKIP_TAILSCALE:=0}"
: "${SKIP_FIREWALL:=0}"

# Ensure base dirs
mkdir -p /etc/pid /var/lib/pid /opt/pid-infra
chmod 0750 /etc/pid

# Load per-site env (normalize CRLF)
if [ -f /opt/pid-infra/seed/site.env ]; then sed -i 's/\r$//' /opt/pid-infra/seed/site.env || true; fi
if [ -f /etc/pid/site.env ]; then sed -i 's/\r$//' /etc/pid/site.env || true; fi
# Prefer /etc/pid/site.env; fall back to seed
if [ -f /etc/pid/site.env ]; then set -a && . /etc/pid/site.env && set +a
elif [ -f /opt/pid-infra/seed/site.env ]; then cp /opt/pid-infra/seed/site.env /etc/pid/site.env && chmod 0640 /etc/pid/site.env && chgrp adm /etc/pid/site.env && set -a && . /etc/pid/site.env && set +a
fi

# Baseline packages
apt-get update -y
apt-get install -y ca-certificates curl jq git gnupg python3-venv openssl ufw unattended-upgrades

# Unattended upgrades + reboot window
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
sed -i 's#^//\?Unattended-Upgrade::Automatic-Reboot .*#Unattended-Upgrade::Automatic-Reboot "true";#' /etc/apt/apt.conf.d/50unattended-upgrades || true
grep -q Automatic-Reboot-Time /etc/apt/apt.conf.d/50unattended-upgrades || echo 'Unattended-Upgrade::Automatic-Reboot-Time "04:00";' >> /etc/apt/apt.conf.d/50unattended-upgrades
systemctl restart unattended-upgrades.service || true

# Hostname (safe)
HN="$(printf '%s' "${HOSTNAME:-${SITE_ID:+pid-${SITE_ID}}}" | tr -d '\r' | xargs || true)"
[[ "${HN:-}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || HN=edge-node
hostnamectl set-hostname --static "$HN"
hostnamectl set-hostname --pretty "$HN"
echo "[firstboot] hostname set to $HN"

# SSH baseline (no firewall yet)
sed -i "s/^#\?PermitRootLogin.*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config
grep -q "^AllowUsers" /etc/ssh/sshd_config || echo "AllowUsers edgeadm" >> /etc/ssh/sshd_config
systemctl restart ssh || true

# Tailscale (gate firewall on success)
ts_ready=0
if [ "$SKIP_TAILSCALE" -ne 1 ]; then
  if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  systemctl enable --now tailscaled
  TS_ARGS=(--ssh --accept-dns=false)
  [ -n "${TS_AUTHKEY:-}" ] && TS_ARGS+=(--authkey="$TS_AUTHKEY")
  [ -n "${TS_TAGS:-}" ]   && TS_ARGS+=(--advertise-tags="$TS_TAGS")
  [ -n "$HN" ]            && TS_ARGS+=(--hostname="$HN")
  for i in 1 2 3 4 5 6; do
    if tailscale up "${TS_ARGS[@]}"; then
      if tailscale ip -4 >/dev/null 2>&1; then
        ts_ready=1; touch /var/lib/pid/tailscale.ready; break
      fi
    fi
    sleep $((i*5))
  done
  echo "[firstboot] tailscale ready=$ts_ready"
fi

# Firewall (only lock down if Tailscale up)
if [ "$SKIP_FIREWALL" -ne 1 ]; then
  ufw default deny incoming
  if [ "$ts_ready" -eq 1 ]; then
    for p in 22 8080 8090 8086; do ufw allow in on tailscale0 to any port $p proto tcp; done
    ufw --force enable
    echo "[firstboot] UFW enabled with tailnet rules"
  else
    echo "[firstboot] WARN: Tailscale not ready; leaving UFW disabled to avoid lockout"
    ufw disable || true
  fi
fi

# Docker + Compose
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
  apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
fi

# Seed infra compose: copy if missing; generate .env if missing
install -d /opt/pid-infra/infra
if [ ! -f /opt/pid-infra/infra/compose.yml ]; then
  echo "[firstboot] copying infra compose from repo"
fi
# Ensure CHIRPSTACK_PG_PASS exists
if [ ! -f /opt/pid-infra/infra/.env ]; then
  CS_PG_PASS="${CHIRPSTACK_PG_PASS:-$(openssl rand -base64 18 | tr -d '=+/;' | cut -c1-24)}"
  echo "CHIRPSTACK_PG_PASS=${CS_PG_PASS}" > /opt/pid-infra/infra/.env
fi

docker compose -f /opt/pid-infra/infra/compose.yml --env-file /opt/pid-infra/infra/.env up -d

# Install systemd units
cp -a /opt/pid-infra/units/*.service /etc/systemd/system/
cp -a /opt/pid-infra/units/*.timer   /etc/systemd/system/ 2>/dev/null || true
systemctl daemon-reload

# Place scripts into PATH (so autoinstall YAML can call them too)
install -m 0755 /opt/pid-infra/scripts/init-influx.sh     /usr/local/sbin/
install -m 0755 /opt/pid-infra/scripts/init-chirpstack.sh /usr/local/sbin/
install -m 0755 /opt/pid-infra/scripts/pid-edge-agent.sh  /usr/local/sbin/
install -m 0755 /opt/pid-infra/scripts/pid-selftest.sh    /usr/local/sbin/
install -m 0755 /opt/pid-infra/scripts/pid-failsafe.sh    /usr/local/sbin/

# One-time initializers (idempotent)
 /usr/local/sbin/init-influx.sh || true
 /usr/local/sbin/init-chirpstack.sh || true

# Enable agent + selftest + failsafe
systemctl enable --now pid-edge-agent.timer || true
systemctl enable --now pid-selftest.timer   || true
systemctl enable --now pid-failsafe.timer   || true

echo "[firstboot] complete"
