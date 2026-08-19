#!/bin/bash
# ---------------------------------------------------------------------------
# The supervisor. Runs every minute from appcli-watchdog.timer.
#
# Healthy path (the 99% case) - costs nothing, takes ~1 second:
#   publish ServiceUp=1 and exit.
#
# Unhealthy path:
#   1. publish ServiceUp=0                       -> CloudWatch alarm
#   2. SNS alert immediately with the log tail   -> you know within seconds
#   3. hand the failure to Claude for diagnosis  -> written to the watchdog log
#   4. restart the service
#   5. if it is crash-looping, stop restarting and escalate instead of
#      hammering a remote site with a broken client
#
# Note that systemd already restarts the process on its own within 10 seconds.
# This watchdog exists for what systemd cannot do: tell you WHY, and notice the
# difference between "restarted once" and "has restarted 30 times in an hour".
# ---------------------------------------------------------------------------
set -uo pipefail

# shellcheck disable=SC1091
source /etc/appcli/runner.env

SERVICE=appcli.service
STATE_DIR=/var/lib/appcli/watchdog
LOG=/var/log/appcli/watchdog.log
LOCK=/var/lock/appcli-watchdog.lock
CLAUDE_REPORTS=/var/log/appcli/claude
APP_LOG=/var/log/appcli/app.log

# Stop restarting after this many restarts inside the window, and escalate.
CRASHLOOP_MAX=${CRASHLOOP_MAX:-6}
CRASHLOOP_WINDOW_SEC=${CRASHLOOP_WINDOW_SEC:-1800}
# Do not spend money asking Claude about the same failure every single minute.
CLAUDE_COOLDOWN_SEC=${CLAUDE_COOLDOWN_SEC:-900}

mkdir -p "$STATE_DIR" "$CLAUDE_REPORTS" "$(dirname "$LOG")"

log() { echo "[watchdog $(date -Is)] $*" | tee -a "$LOG"; }

# --- manual controls -------------------------------------------------------
case "${1:-}" in
  --resume)
    rm -f "$STATE_DIR/restarts" "$STATE_DIR/crashloop_alerted" "$STATE_DIR/alerted"
    systemctl reset-failed "$SERVICE" 2>/dev/null || true
    systemctl restart "$SERVICE"
    log "crash-loop hold cleared by operator; $SERVICE restarted"
    exit 0
    ;;
  --status)
    echo "service:   $(systemctl is-active "$SERVICE")"
    echo "restarts:  $(wc -l < "$STATE_DIR/restarts" 2>/dev/null || echo 0) in the window"
    echo "held:      $([ -f "$STATE_DIR/crashloop_alerted" ] && echo yes || echo no)"
    echo "reports:   $CLAUDE_REPORTS"
    ls -t "$CLAUDE_REPORTS"/*.md 2>/dev/null | head -5
    exit 0
    ;;
esac

put_metric() {
  aws cloudwatch put-metric-data \
    --region "$AWS_REGION" \
    --namespace "$METRIC_NAMESPACE" \
    --metric-name "$1" \
    --value "$2" \
    --unit Count >/dev/null 2>&1 \
    || log "WARN: could not publish metric $1"
}

# Only ever one watchdog at a time. A Claude diagnosis can take a few minutes
# and the timer would otherwise start stacking runs on top of it.
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "[watchdog $(date -Is)] previous run still in progress, skipping" >> "$LOG"
  exit 0
fi

# ---------------------------------------------------------------------------
# Healthy?
# ---------------------------------------------------------------------------
if systemctl is-active --quiet "$SERVICE"; then
  put_metric ServiceUp 1

  # Clear the "we already alerted about this" flag so the next distinct outage
  # is treated as new.
  if [ -f "$STATE_DIR/alerted" ]; then
    rm -f "$STATE_DIR/alerted"
    log "service recovered"
    /opt/appcli/bin/notify.sh "RECOVERED" "$SERVICE is running again." || true
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Unhealthy from here down
# ---------------------------------------------------------------------------
put_metric ServiceUp 0
STATUS="$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
log "service is DOWN (state=$STATUS)"

# --- crash-loop accounting -------------------------------------------------
NOW=$(date +%s)
touch "$STATE_DIR/restarts"
# keep only timestamps inside the window
awk -v cutoff="$((NOW - CRASHLOOP_WINDOW_SEC))" '$1 >= cutoff' \
  "$STATE_DIR/restarts" > "$STATE_DIR/restarts.tmp" || true
mv "$STATE_DIR/restarts.tmp" "$STATE_DIR/restarts"
RESTART_COUNT=$(wc -l < "$STATE_DIR/restarts" | tr -d ' ')

# --- gather evidence -------------------------------------------------------
UNIT_LOG="$(journalctl -u "$SERVICE" -n 120 --no-pager 2>/dev/null || echo '(journal unavailable)')"
TAIL_LOG="$(tail -n 200 "$APP_LOG" 2>/dev/null || echo '(no app log yet)')"
EXIT_INFO="$(systemctl show "$SERVICE" -p ExecMainStatus -p Result -p NRestarts --no-pager 2>/dev/null)"

EVIDENCE_FILE="$STATE_DIR/last_failure.txt"
{
  echo "=== systemctl show ==="; echo "$EXIT_INFO"
  echo; echo "=== journalctl -u $SERVICE (last 120) ==="; echo "$UNIT_LOG"
  echo; echo "=== tail -200 $APP_LOG ==="; echo "$TAIL_LOG"
} > "$EVIDENCE_FILE"

# --- alert immediately, before doing anything slow -------------------------
if [ ! -f "$STATE_DIR/alerted" ]; then
  touch "$STATE_DIR/alerted"
  /opt/appcli/bin/notify.sh "SERVICE DOWN" \
"$SERVICE is not running (state: $STATUS).
Restarts in the last $((CRASHLOOP_WINDOW_SEC / 60)) minutes: $RESTART_COUNT

Last log lines:
$(echo "$TAIL_LOG" | tail -n 25)

Claude is diagnosing now; a follow-up will arrive with what it found." || true
fi

# ---------------------------------------------------------------------------
# Crash loop -> stop restarting. Repeatedly firing a broken client at a remote
# site is worse than being down, so we hold and escalate instead.
# ---------------------------------------------------------------------------
if [ "$RESTART_COUNT" -ge "$CRASHLOOP_MAX" ]; then
  log "CRASH LOOP: $RESTART_COUNT restarts in the window - holding, not restarting"
  if [ ! -f "$STATE_DIR/crashloop_alerted" ]; then
    touch "$STATE_DIR/crashloop_alerted"
    /opt/appcli/bin/notify.sh "CRASH LOOP - AUTO-RESTART PAUSED" \
"$SERVICE has failed $RESTART_COUNT times in $((CRASHLOOP_WINDOW_SEC / 60)) minutes.
Automatic restarts are PAUSED so a broken client is not hammering the target site.

This needs a look. Evidence: $EVIDENCE_FILE
Latest Claude report: $(ls -t "$CLAUDE_REPORTS"/*.md 2>/dev/null | head -1 || echo none)

Resume with:  sudo /opt/appcli/bin/watchdog.sh --resume" || true
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Ask Claude what happened
# ---------------------------------------------------------------------------
run_claude() {
  command -v claude >/dev/null 2>&1 || { log "claude not installed, skipping diagnosis"; return; }

  local last_run=0
  [ -f "$STATE_DIR/claude_last_run" ] && last_run="$(cat "$STATE_DIR/claude_last_run")"
  if [ $((NOW - last_run)) -lt "$CLAUDE_COOLDOWN_SEC" ]; then
    log "Claude ran $((NOW - last_run))s ago, inside the ${CLAUDE_COOLDOWN_SEC}s cooldown - skipping"
    return
  fi
  date +%s > "$STATE_DIR/claude_last_run"

  ANTHROPIC_API_KEY="$(aws secretsmanager get-secret-value \
      --region "$AWS_REGION" --secret-id "$CLAUDE_SECRET_ID" \
      --query SecretString --output text 2>/dev/null)"
  if [ -z "${ANTHROPIC_API_KEY:-}" ] || [ "$ANTHROPIC_API_KEY" = "None" ]; then
    log "no Anthropic API key in $CLAUDE_SECRET_ID - skipping diagnosis"
    return
  fi
  export ANTHROPIC_API_KEY
  export HOME=/var/lib/appcli/claude-home

  local report
  report="$CLAUDE_REPORTS/$(date +%Y%m%d-%H%M%S).md"

  # Arrays, not strings: tool patterns contain both spaces and '*', so an
  # unquoted string here would word-split AND glob-expand into nonsense.
  local tools=(Read Grep Glob)
  local mode=(--permission-mode plan)
  local task="Do NOT modify any files. Produce a diagnosis only."

  if [ "${CLAUDE_AUTOFIX:-false}" = "true" ]; then
    tools=(Read Grep Glob Edit Write "Bash(git *)" "Bash(/opt/appcli/app/.venv/bin/python *)")
    mode=(--permission-mode acceptEdits)
    task="If - and only if - the cause is an obvious, small, low-risk code defect, fix it. \
Commit the fix on a branch named claude-autofix with a clear message. Never push, never \
touch main, never change credentials or configuration, never widen network access. \
If the cause is anything else - a network block, a captcha, an expired credential, a \
change on the remote site, an ambiguous failure - do NOT edit anything. Report only."
  fi

  log "asking Claude to diagnose (autofix=${CLAUDE_AUTOFIX:-false}, model=$CLAUDE_MODEL)"

  local prompt
  prompt="A long-running Python CLI on this EC2 box has stopped. You are the on-call supervisor.

The application source is at /opt/appcli/app. The failure evidence is at $EVIDENCE_FILE - read it first.

It has failed $RESTART_COUNT times in the last $((CRASHLOOP_WINDOW_SEC / 60)) minutes.

$task

Write your answer as short markdown with exactly these sections:
## What happened
## Root cause
## Confidence  (high / medium / low - say low if you are guessing)
## Action taken
## What the operator must do
Be concrete and brief. Quote the exact log line that gave it away. If you cannot tell from
the evidence, say so plainly rather than inventing a cause."

  # No --max-turns flag exists on the CLI, so `timeout` is the hard stop.
  if timeout 420 claude -p "$prompt" \
       --model "$CLAUDE_MODEL" \
       --add-dir /opt/appcli/app \
       --allowedTools "${tools[@]}" \
       "${mode[@]}" \
       --output-format text > "$report" 2>>"$LOG"; then
    log "Claude report written to $report"
  else
    log "WARN: Claude run failed or timed out (exit $?)"
    echo -e "\n(diagnosis run failed or timed out)" >> "$report"
  fi

  chmod 0644 "$report"
  /opt/appcli/bin/notify.sh "DIAGNOSIS" "$(head -c 3000 "$report")" || true
}

run_claude

# ---------------------------------------------------------------------------
# Restart
# ---------------------------------------------------------------------------
echo "$NOW" >> "$STATE_DIR/restarts"
put_metric Restarts 1
log "restarting $SERVICE"
systemctl reset-failed "$SERVICE" 2>/dev/null || true
systemctl restart "$SERVICE"

sleep 10
if systemctl is-active --quiet "$SERVICE"; then
  log "restart succeeded"
  put_metric ServiceUp 1
else
  log "restart did NOT bring the service up"
fi
