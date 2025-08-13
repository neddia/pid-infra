#!/usr/bin/env bash
set -euo pipefail
if ! ip link show tailscale0 >/dev/null 2>&1; then
  echo "[failsafe] tailscale0 missing: enabling UFW + SSH on all interfaces"
  apt-get update -y && apt-get install -y ufw
  ufw default deny incoming
  ufw allow 22/tcp
  ufw --force enable
fi
