#!/usr/bin/env bash
set -euo pipefail
APP_REPO="${APP_REPO:-https://github.com/you/pid-app.git}"
APP_TAG="${APP_TAG:-}"     # set in /etc/pid/site.env to auto-deploy a tag
APP_BASE="/opt/pid-app"
CURR="$APP_BASE/current"
UNITS=("pid-poller.service" "pid-config-server.service")

mkdir -p "$APP_BASE/releases"
[ -f /etc/pid/site.env ] && set -a && . /etc/pid/site.env && set +a

if [ -z "${APP_TAG}" ]; then
  echo "[edge-agent] APP_TAG not set; nothing to deploy"; exit 0
fi

TARGET="$APP_BASE/releases/${APP_TAG}"
if [ ! -d "$TARGET" ]; then
  echo "[edge-agent] staging ${APP_TAG} from ${APP_REPO}"
  tmp=$(mktemp -d)
  git clone --depth=1 --branch "${APP_TAG}" "${APP_REPO}" "$tmp"
  mkdir -p "$TARGET"
  rsync -a --delete "$tmp"/ "$TARGET"/
  rm -rf "$tmp"
  python3 -m venv "$TARGET/.venv"
  "$TARGET/.venv/bin/pip" install --upgrade pip
  if [ -f "$TARGET/requirements.lock" ]; then
    "$TARGET/.venv/bin/pip" install --require-hashes -r "$TARGET/requirements.lock"
  else
    "$TARGET/.venv/bin/pip" install -r "$TARGET/requirements.txt"
  fi
fi

ln -sfn "$TARGET" "$CURR"
systemctl daemon-reload
for u in "${UNITS[@]}"; do systemctl restart "$u" || true; done

# Health probes (basic)
curl -fsS http://127.0.0.1:8086/health >/dev/null || { echo "[edge-agent] Influx unhealthy"; exit 1; }
curl -fsS http://127.0.0.1:8080/ >/dev/null || { echo "[edge-agent] ChirpStack probe failed"; exit 1; }
echo "[edge-agent] deploy OK: ${APP_TAG}"
