# Runbook

Written for the moment something is wrong and you want the answer, not a tutorial.

## Get a shell on the box

```bash
aws ssm start-session --region <region> --target <instance-id>
sudo -i
```

No SSH key, no open port. If `start-session` says the target is not connected, the SSM
agent is not running — see "The box is unreachable" below.

## The five commands that answer almost everything

```bash
systemctl status appcli.service          # is it running, and why did it stop
journalctl -u appcli.service -n 100      # what systemd saw
tail -f /var/log/appcli/app.log          # what your code printed
tail -f /var/log/appcli/watchdog.log     # what the watchdog did about it
ls -lt /var/log/appcli/claude/           # Claude's diagnoses, newest first
```

From your own laptop, without logging in:

```bash
aws logs tail /<project>/app --follow --region <region>
aws logs tail /<project>/watchdog --follow --region <region>
```

---

## "I got a SERVICE DOWN email"

1. Wait 60 seconds. systemd restarts within 10s and the watchdog confirms within a
   minute; if a RECOVERED email follows, it was a transient blip and there is nothing
   to do. This is the normal case.
2. No RECOVERED email? Read the newest file in `/var/log/appcli/claude/` — Claude has
   already read the logs and written up what it thinks happened.
3. Check its **Confidence** line before acting on it. `low` means it is guessing from
   thin evidence, and you should read the raw log yourself.

## "I got a CRASH LOOP email — auto-restart is PAUSED"

The service failed 6 times in 30 minutes, so the watchdog deliberately stopped
restarting it. This is on purpose: repeatedly firing a broken client at a remote site is
worse than being down.

```bash
sudo /opt/appcli/bin/watchdog.sh --status     # what it knows
cat /var/lib/appcli/watchdog/last_failure.txt # the full evidence bundle
# ...fix the actual problem, then:
sudo /opt/appcli/bin/watchdog.sh --resume     # clears the hold and restarts
```

## "It says running, but it is not doing anything"

A hung process still counts as "active" to systemd. Check the log timestamps:

```bash
tail -3 /var/log/appcli/app.log; date
```

If the last line is old, it is wedged rather than crashed. `systemctl restart
appcli.service` clears it. If it keeps happening, the fix belongs in your code — an
overall timeout on whatever it blocks on (`requests` without a `timeout=` argument will
hang forever, which is the usual culprit).

## "No alerts are arriving"

In order of likelihood:

1. **The SNS subscription was never confirmed.** This is nearly always it.
   `aws sns list-subscriptions-by-topic --topic-arn <arn>` — anything showing
   `PendingConfirmation` sends nothing. Re-send with
   `aws sns subscribe --topic-arn <arn> --protocol email --notification-endpoint you@example.com`
2. Check spam. The first one from `no-reply@sns.amazonaws.com` often lands there.
3. `sudo /opt/appcli/bin/notify.sh "TEST" "testing"` — if that errors, it is IAM.

## "The box is unreachable"

```bash
aws ec2 describe-instance-status --instance-ids <id> --include-all-instances
```

- `running` + status checks failing → the alarm reboots it automatically within ~2
  minutes. Wait.
- `stopped` → `aws ec2 start-instances --instance-ids <id>`
- Genuinely broken → `terraform taint aws_instance.app && terraform apply` rebuilds it
  from scratch in about 5 minutes. Nothing is stored on the instance that is not in git
  or Secrets Manager, so this is safe. The Elastic IP stays the same.

## Deploying new code

```bash
git push                                    # to your app repo
aws ssm start-session --target <instance-id>
sudo /opt/appcli/bin/deploy.sh
```

Pulls, reinstalls dependencies, restarts, and waits 15s. If the service will not stay
up, it **automatically restores the previous release** and emails you. A bad push
cannot leave you with nothing running.

## Rotating secrets

```bash
# Anthropic key
aws secretsmanager put-secret-value --secret-id <project>-claude --secret-string 'sk-ant-...'

# Your app's secrets (whole JSON object, replaces the previous value)
aws secretsmanager put-secret-value --secret-id <project>-app \
  --secret-string '{"PORTAL_USER":"...","PORTAL_PASS":"..."}'

sudo systemctl restart appcli.service   # app secrets are read at start-up
```

The Claude key is read fresh on every watchdog run, so that one needs no restart.

## Turning the Claude auto-fix on or off

Off by default: Claude diagnoses and reports, but never edits code.

```hcl
claude_autofix = true    # in terraform.tfvars, then terraform apply
```

With it on, Claude may edit the app and commit to a local `claude-autofix` branch. It
never pushes, never touches `main`, and is instructed to report rather than edit
whenever the cause is anything other than an obvious small code defect. Review with:

```bash
sudo -u appcli git -C /opt/appcli/app log --oneline claude-autofix
sudo -u appcli git -C /opt/appcli/app diff main claude-autofix
```

Leave it off until you have watched its read-only diagnoses for a week and agree with
them.

## Cost control

```bash
sudo /opt/appcli/bin/watchdog.sh --status    # how often Claude has been invoked
```

Claude only runs on failure, and no more than once every 15 minutes
(`CLAUDE_COOLDOWN_SEC`). A healthy month costs nothing in API calls. If a bill surprises
you, the billing alarm should have emailed you first — check that alarm exists.

## Shutting it all down

```bash
cd terraform && terraform destroy
```

Removes everything including the secrets. Nothing is left behind to bill you.
