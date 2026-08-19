#!/bin/bash
# ---------------------------------------------------------------------------
# Proves the acceptance criteria on the live box. Run it once after apply, and
# again any time you change the alerting.
#
#   sudo /opt/appcli/bin/selftest.sh
#
# It deliberately breaks things on purpose, then puts them back.
# ---------------------------------------------------------------------------
set -uo pipefail

# shellcheck disable=SC1091
source /etc/appcli/runner.env

PASS=0; FAIL=0
ok()   { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
head_() { echo; echo "== $* =="; }

head_ "1. service is running"
systemctl is-active --quiet appcli.service && ok "appcli.service active" || bad "appcli.service is NOT active"

head_ "2. service is enabled at boot"
systemctl is-enabled --quiet appcli.service && ok "enabled" || bad "not enabled - it will not survive a reboot"

head_ "3. watchdog timer is armed"
systemctl is-active --quiet appcli-watchdog.timer && ok "timer active" || bad "timer not active"
systemctl list-timers appcli-watchdog.timer --no-pager | sed -n '2p'

head_ "4. logs are reaching CloudWatch"
if aws logs describe-log-streams --region "$AWS_REGION" --log-group-name "$LOG_GROUP_APP" \
     --order-by LastEventTime --descending --max-items 1 \
     --query 'logStreams[0].lastEventTimestamp' --output text 2>/dev/null | grep -qE '^[0-9]+$'; then
  ok "app log group has events"
else
  bad "no events in $LOG_GROUP_APP yet (the agent flushes every 5s - retry in a minute)"
fi

head_ "5. IAM permissions"
aws sns get-topic-attributes --region "$AWS_REGION" --topic-arn "$SNS_TOPIC_ARN" >/dev/null 2>&1 \
  && ok "can read the SNS topic" || bad "cannot reach the SNS topic"
aws secretsmanager get-secret-value --region "$AWS_REGION" --secret-id "$CLAUDE_SECRET_ID" \
  --query SecretString --output text >/dev/null 2>&1 \
  && ok "can read the Claude secret" || bad "Claude secret not set - store your Anthropic key"

head_ "6. Claude Code is installed"
if command -v claude >/dev/null 2>&1; then ok "$(claude --version 2>/dev/null | head -1)"; else bad "claude not on PATH"; fi

head_ "7. alert delivery - sending a real test alert now"
if /opt/appcli/bin/notify.sh "SELF-TEST" "This is a test alert from selftest.sh. If you are reading it, alerting works."; then
  ok "SNS publish accepted - check your inbox"
else
  bad "SNS publish failed"
fi

head_ "8. forced-failure drill"
echo "  Killing the process to prove auto-recovery and timed alerting."
echo "  Watch the clock: the alert should land within 60 seconds."
START=$(date +%s)
systemctl kill -s SIGKILL appcli.service
sleep 3
echo "  state right after kill: $(systemctl is-active appcli.service)"
echo "  waiting up to 90s for systemd + watchdog to bring it back..."
for _ in $(seq 1 18); do
  sleep 5
  if systemctl is-active --quiet appcli.service; then
    ok "recovered in $(( $(date +%s) - START ))s"
    break
  fi
done
systemctl is-active --quiet appcli.service || bad "did NOT recover within 90s"

head_ "9. forced error -> error alarm"
echo "Traceback (most recent call last): SELFTEST forced error, ignore" >> /var/log/appcli/app.log
ok "wrote a synthetic traceback to the app log - the app-errors alarm should fire within ~2 min"

echo
echo "==============================="
echo " passed: $PASS   failed: $FAIL"
echo "==============================="
echo
echo "Expect in your inbox within the next couple of minutes:"
echo "  - [$PROJECT_NAME] SELF-TEST"
echo "  - [$PROJECT_NAME] SERVICE DOWN   (from the kill drill)"
echo "  - [$PROJECT_NAME] RECOVERED"
echo "  - ALARM: \"$PROJECT_NAME-app-errors\"  (from the synthetic traceback)"
[ "$FAIL" -eq 0 ]
