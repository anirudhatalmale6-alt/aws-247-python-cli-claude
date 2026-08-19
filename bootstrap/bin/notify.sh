#!/bin/bash
# ---------------------------------------------------------------------------
# notify.sh "SUBJECT" "body text"
#
# Publishes straight to SNS. This is the path that actually meets the
# "alert within one minute" requirement - it fires in under a second.
# The CloudWatch alarms are the safety net for things the box cannot report
# itself, such as the whole instance dying.
#
# SNS email subject lines are limited to 100 chars and may not contain newlines.
# ---------------------------------------------------------------------------
set -uo pipefail

# shellcheck disable=SC1091
source /etc/appcli/runner.env

SUBJECT_RAW="${1:-Alert}"
BODY="${2:-(no details)}"

INSTANCE_ID="$(curl -s -m 2 -H "X-aws-ec2-metadata-token: $(
  curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" \
  http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo unknown)"

SUBJECT="[$PROJECT_NAME] $SUBJECT_RAW"
SUBJECT="$(echo "$SUBJECT" | tr -d '\n\r' | cut -c1-99)"

FULL_BODY="$BODY

--
project:  $PROJECT_NAME
host:     $(hostname)
instance: $INSTANCE_ID
time:     $(date -Is)
logs:     aws logs tail $LOG_GROUP_APP --follow --region $AWS_REGION
shell:    aws ssm start-session --region $AWS_REGION --target $INSTANCE_ID"

aws sns publish \
  --region "$AWS_REGION" \
  --topic-arn "$SNS_TOPIC_ARN" \
  --subject "$SUBJECT" \
  --message "$FULL_BODY" >/dev/null

echo "[notify] sent: $SUBJECT"
