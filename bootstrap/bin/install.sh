#!/bin/bash
# ---------------------------------------------------------------------------
# One-shot installer. Called by EC2 user-data on first boot, and safe to re-run
# by hand afterwards (it is idempotent) after a `git pull` in /opt/bootstrap.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFIX=/opt/appcli
SERVICE_USER=appcli

log() { echo "[install $(date -Is)] $*"; }

# shellcheck disable=SC1091
source /etc/appcli/runner.env

# ---------------------------------------------------------------------------
# 1. Packages
# ---------------------------------------------------------------------------
log "installing OS packages"
dnf -y install \
  python3.11 python3.11-pip python3.11-devel \
  gcc make openssl-devel libffi-devel \
  git jq tar gzip cronie procps-ng \
  amazon-cloudwatch-agent >/dev/null

# Chromium + the shared libraries Playwright/Selenium need. Harmless if the CLI
# is pure-requests; essential if it drives a browser.
dnf -y install chromium chromedriver nss atk at-spi2-atk cups-libs libdrm \
  libxkbcommon libXcomposite libXdamage libXfixes libXrandr mesa-libgbm \
  alsa-lib pango cairo >/dev/null 2>&1 || log "WARN: browser libs unavailable, skipping"

# ---------------------------------------------------------------------------
# 2. Service account and directory layout
# ---------------------------------------------------------------------------
id -u "$SERVICE_USER" >/dev/null 2>&1 || useradd --system --create-home \
  --home-dir /var/lib/appcli --shell /bin/bash "$SERVICE_USER"

install -d -m 0755 "$PREFIX" "$PREFIX/bin"
install -d -m 0755 -o "$SERVICE_USER" -g "$SERVICE_USER" "$PREFIX/app" /var/log/appcli /var/lib/appcli/claude-home

install -m 0755 "$REPO_DIR/bootstrap/bin/"*.sh "$PREFIX/bin/"

# ---------------------------------------------------------------------------
# 3. Claude Code
#    Native installer first - it is a single self-contained binary and needs no
#    Node runtime. npm is kept as a fallback for the rare case the CDN is blocked.
# ---------------------------------------------------------------------------
log "installing Claude Code"
if ! command -v claude >/dev/null 2>&1; then
  if curl -fsSL https://claude.ai/install.sh | bash -s -- --install-dir /usr/local/bin >/dev/null 2>&1; then
    log "Claude Code installed via native installer"
  else
    log "native installer failed, falling back to npm"
    dnf -y install nodejs20 nodejs20-npm >/dev/null 2>&1 || dnf -y install nodejs npm >/dev/null
    npm install -g @anthropic-ai/claude-code >/dev/null
  fi
fi
command -v claude >/dev/null 2>&1 || log "WARN: Claude Code not on PATH - the watchdog will still alert and restart, just without AI diagnosis"

# ---------------------------------------------------------------------------
# 4. Application code
# ---------------------------------------------------------------------------
log "deploying application"
"$PREFIX/bin/deploy.sh" --initial

# ---------------------------------------------------------------------------
# 5. CloudWatch agent
# ---------------------------------------------------------------------------
log "configuring CloudWatch agent"
CW_CFG=/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
sed \
  -e "s|__LOG_GROUP_APP__|$LOG_GROUP_APP|g" \
  -e "s|__LOG_GROUP_WATCHDOG__|$LOG_GROUP_WATCHDOG|g" \
  -e "s|__LOG_GROUP_SYSTEM__|$LOG_GROUP_SYSTEM|g" \
  "$REPO_DIR/bootstrap/config/amazon-cloudwatch-agent.json" > "$CW_CFG"

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s -c "file:$CW_CFG" >/dev/null

# ---------------------------------------------------------------------------
# 6. systemd units
# ---------------------------------------------------------------------------
log "installing systemd units"
install -m 0644 "$REPO_DIR/bootstrap/systemd/appcli.service"          /etc/systemd/system/
install -m 0644 "$REPO_DIR/bootstrap/systemd/appcli-watchdog.service" /etc/systemd/system/
sed "s|__INTERVAL__|${WATCHDOG_INTERVAL_MINUTES:-1}|g" \
  "$REPO_DIR/bootstrap/systemd/appcli-watchdog.timer" > /etc/systemd/system/appcli-watchdog.timer

systemctl daemon-reload
systemctl enable --now appcli.service
systemctl enable --now appcli-watchdog.timer

# ---------------------------------------------------------------------------
# 7. Log rotation - a 24/7 process will happily fill a 20 GB disk otherwise
# ---------------------------------------------------------------------------
cat > /etc/logrotate.d/appcli <<'EOF'
/var/log/appcli/*.log {
    daily
    rotate 7
    size 50M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF

log "install complete"
systemctl --no-pager --lines=0 status appcli.service || true
