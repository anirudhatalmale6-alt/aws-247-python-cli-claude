#!/bin/bash
# ---------------------------------------------------------------------------
# Pull the latest application code and restart the service.
#
#   sudo /opt/appcli/bin/deploy.sh              # normal redeploy
#   sudo /opt/appcli/bin/deploy.sh --initial    # first install, called by install.sh
#
# If anything fails - clone, pip install, or the service refusing to come back up
# - the previous release is restored and an alert is sent. A bad push should
# never leave you with nothing running.
# ---------------------------------------------------------------------------
set -euo pipefail

PREFIX=/opt/appcli
APP_DIR="$PREFIX/app"
BACKUP_DIR="$PREFIX/app.previous"
SERVICE_USER=appcli
INITIAL=false
if [ "${1:-}" = "--initial" ]; then INITIAL=true; fi

# shellcheck disable=SC1091
source /etc/appcli/runner.env
if [ -f /etc/appcli/git.env ]; then
  # shellcheck disable=SC1091
  source /etc/appcli/git.env
fi

log() { echo "[deploy $(date -Is)] $*"; }

authed_url() {
  local url="$1"
  if [ -n "${APP_GIT_TOKEN:-}" ] && [[ "$url" == https://* ]]; then
    echo "https://x-access-token:${APP_GIT_TOKEN}@${url#https://}"
  else
    echo "$url"
  fi
}

# ---------------------------------------------------------------------------
# No repo configured yet -> install the bundled demo so the whole pipeline can
# be proven end to end before the real code arrives.
# ---------------------------------------------------------------------------
if [ -z "${APP_REPO_URL:-}" ]; then
  log "APP_REPO_URL is empty - deploying the bundled demo worker"
  install -d -o "$SERVICE_USER" -g "$SERVICE_USER" "$APP_DIR"
  install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0644 \
    /opt/bootstrap/examples/demo_worker.py "$APP_DIR/main.py"
  printf '' > "$APP_DIR/requirements.txt"
  chown -R "$SERVICE_USER:$SERVICE_USER" "$APP_DIR"
else
  if [ -d "$APP_DIR/.git" ]; then
    log "updating existing checkout"
    rm -rf "$BACKUP_DIR"
    cp -a "$APP_DIR" "$BACKUP_DIR"
    sudo -u "$SERVICE_USER" git -C "$APP_DIR" remote set-url origin "$(authed_url "$APP_REPO_URL")"
    sudo -u "$SERVICE_USER" git -C "$APP_DIR" fetch --depth 1 origin "$APP_BRANCH"
    sudo -u "$SERVICE_USER" git -C "$APP_DIR" reset --hard "origin/$APP_BRANCH"
    sudo -u "$SERVICE_USER" git -C "$APP_DIR" clean -fd -e .venv
  else
    log "fresh clone of $APP_REPO_URL ($APP_BRANCH)"
    rm -rf "$APP_DIR"
    install -d -o "$SERVICE_USER" -g "$SERVICE_USER" "$APP_DIR"
    sudo -u "$SERVICE_USER" git clone --depth 1 --branch "$APP_BRANCH" \
      "$(authed_url "$APP_REPO_URL")" "$APP_DIR"
  fi
  # Strip the token straight back out so it is not sitting in .git/config.
  sudo -u "$SERVICE_USER" git -C "$APP_DIR" remote set-url origin "$APP_REPO_URL"
fi

# ---------------------------------------------------------------------------
# Virtualenv
# ---------------------------------------------------------------------------
if [ ! -x "$APP_DIR/.venv/bin/python" ]; then
  log "creating virtualenv"
  sudo -u "$SERVICE_USER" python3.11 -m venv "$APP_DIR/.venv"
fi

sudo -u "$SERVICE_USER" "$APP_DIR/.venv/bin/pip" install --upgrade pip wheel >/dev/null

if [ -f "$APP_DIR/requirements.txt" ] && [ -s "$APP_DIR/requirements.txt" ]; then
  log "installing requirements.txt"
  sudo -u "$SERVICE_USER" "$APP_DIR/.venv/bin/pip" install -r "$APP_DIR/requirements.txt"
elif [ -f "$APP_DIR/pyproject.toml" ]; then
  log "installing from pyproject.toml"
  sudo -u "$SERVICE_USER" "$APP_DIR/.venv/bin/pip" install -e "$APP_DIR"
else
  log "no requirements.txt or pyproject.toml found - skipping dependency install"
fi

# Playwright ships its own browser download step.
if sudo -u "$SERVICE_USER" "$APP_DIR/.venv/bin/pip" show playwright >/dev/null 2>&1; then
  log "playwright detected - installing chromium"
  sudo -u "$SERVICE_USER" env HOME=/var/lib/appcli \
    "$APP_DIR/.venv/bin/playwright" install chromium || log "WARN: playwright browser install failed"
fi

# ---------------------------------------------------------------------------
# Restart, and roll back if it will not stay up
# ---------------------------------------------------------------------------
if [ "$INITIAL" = true ]; then
  log "initial deploy - service will be started by install.sh"
  exit 0
fi

log "restarting service"
systemctl restart appcli.service
sleep 15

if systemctl is-active --quiet appcli.service; then
  log "deploy OK - service is running"
  /opt/appcli/bin/notify.sh "DEPLOY OK" "New code is live on $(hostname) and the service is running." || true
  exit 0
fi

log "ERROR: service failed to stay up after deploy"
journalctl -u appcli.service -n 50 --no-pager || true

if [ -d "$BACKUP_DIR" ]; then
  log "rolling back to the previous release"
  rm -rf "$APP_DIR"
  mv "$BACKUP_DIR" "$APP_DIR"
  systemctl restart appcli.service
  sleep 10
  /opt/appcli/bin/notify.sh "DEPLOY FAILED - ROLLED BACK" \
    "The new code would not start. The previous release has been restored and is $(systemctl is-active appcli.service)."
else
  /opt/appcli/bin/notify.sh "DEPLOY FAILED" \
    "The new code would not start and there was no previous release to roll back to."
fi
exit 1
