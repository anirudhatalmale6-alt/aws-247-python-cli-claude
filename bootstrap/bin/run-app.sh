#!/bin/bash
# ---------------------------------------------------------------------------
# ExecStart wrapper for appcli.service.
#
# Fetches the application's secrets from AWS Secrets Manager at start-up and
# exports them as environment variables, so nothing sensitive is ever written to
# disk or committed to git. Then execs the CLI, replacing this shell, so systemd
# supervises the real process directly.
# ---------------------------------------------------------------------------
set -euo pipefail

# shellcheck disable=SC1091
source /etc/appcli/runner.env

APP_DIR=/opt/appcli/app

# --- secrets -> environment ------------------------------------------------
if [ -n "${APP_SECRET_ID:-}" ]; then
  SECRET_JSON="$(aws secretsmanager get-secret-value \
      --secret-id "$APP_SECRET_ID" \
      --query SecretString --output text 2>/dev/null || echo '{}')"

  if echo "$SECRET_JSON" | jq -e 'type == "object"' >/dev/null 2>&1; then
    while IFS='=' read -r key value; do
      [ -z "$key" ] && continue
      [ "$key" = "PLACEHOLDER" ] && continue
      export "$key=$value"
    done < <(echo "$SECRET_JSON" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
  else
    echo "WARN: $APP_SECRET_ID is not a JSON object - skipping secret export" >&2
  fi
fi

# --- runtime ---------------------------------------------------------------
export HOME=/var/lib/appcli
export PYTHONUNBUFFERED=1                      # so logs appear immediately, not on exit
export PYTHONFAULTHANDLER=1                    # dump a traceback on a hard crash
export PATH="$APP_DIR/.venv/bin:$PATH"
export VIRTUAL_ENV="$APP_DIR/.venv"

cd "$APP_DIR"

echo "[run-app] starting: ${APP_ENTRYPOINT:-python -u main.py}"
exec bash -c "${APP_ENTRYPOINT:-python -u main.py}"
