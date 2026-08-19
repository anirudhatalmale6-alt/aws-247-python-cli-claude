# 24/7 Python CLI on AWS, supervised by Claude

Runs a long-running Python CLI on a single EC2 instance so that it:

- **never stays down** — systemd restarts it within 10s of any exit, and the instance
  reboots itself if the hardware check fails
- **tells you the moment it breaks** — an SNS alert fires in under a second, with the
  log tail already in the email
- **explains itself** — Claude Code runs on the box, reads the failure, and sends you a
  diagnosis instead of a bare "service down" ping
- **redeploys in one command** — `git push`, then `deploy.sh`, with automatic rollback
  if the new code will not start
- **is entirely reproducible** — one `terraform apply` builds the whole thing from
  nothing, in any AWS account or region

---

## Quick start

```bash
git clone https://github.com/anirudhatalmale6-alt/aws-247-python-cli-claude.git
cd aws-247-python-cli-claude/terraform

cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars          # at minimum, set alert_email

terraform init
terraform apply
```

Then, once:

```bash
# 1. Click the "Confirm subscription" link AWS emails you. Until you do, no alerts arrive.

# 2. Store your Anthropic API key (terraform prints the exact command)
terraform output -raw set_claude_key_command

# 3. Watch it come up - first boot takes 3-4 minutes
eval "$(terraform output -raw tail_app_logs_command)"

# 4. Prove the alerting works, for real
aws ssm start-session --target "$(terraform output -raw instance_id)"
sudo /opt/appcli/bin/selftest.sh
```

Leave `app_repo_url` empty on the first apply. A demo worker is deployed instead, so you
can prove the entire pipeline — restart, log shipping, alarms, Claude diagnosis — before
your own code is anywhere near it. Then set `app_repo_url` and re-apply.

---

## What gets built

| Resource | Why |
|---|---|
| VPC, public subnet, IGW, egress-only SG | Self-contained, so `destroy` leaves nothing behind |
| EC2 t3.micro + Elastic IP | The runner. Free-tier eligible for 12 months |
| IAM role (SSM, CloudWatch, 2 scoped secrets) | No access keys anywhere, no inbound SSH |
| Secrets Manager × 2 | Anthropic key + your app's own secrets |
| CloudWatch log groups × 3 | app, watchdog/Claude reports, system |
| 4 alarms + SNS topic | errors, service down, EC2 health (auto-reboot), disk |
| Billing alarm | So a mistake cannot quietly cost you money |
| Dashboard | One screen: uptime, errors, live logs |

Running cost is roughly **$8–15/month** after the free tier, plus whatever the Claude
supervisor uses — which is nothing at all while the service is healthy, because it only
calls the API when something has actually broken.

---

## How the layers stack up

There are four independent things keeping the CLI alive. Each one catches what the layer
below it cannot:

1. **systemd `Restart=always`** — process exits, back in 10 seconds. Catches ~95% of it.
2. **`watchdog.sh`, every minute** — knows the difference between "restarted once" and
   "restarted 30 times in an hour". Alerts, asks Claude why, and *stops restarting* if
   it is crash-looping rather than hammering a remote site with a broken client.
3. **CloudWatch alarms** — catch what the box cannot report about itself, including the
   box being gone. The heartbeat alarm treats *missing data* as a failure, which is the
   whole point.
4. **EC2 status-check alarm** — reboots the instance automatically on a hardware or
   kernel-level fault.

## Repo layout

```
terraform/            the whole infrastructure, one apply
bootstrap/bin/        install, deploy, run, watchdog, notify, selftest
bootstrap/systemd/    the service and the watchdog timer
bootstrap/config/     CloudWatch agent config
examples/             demo worker used before your real code is wired in
docs/                 architecture, runbook, AWS account setup
```

Read [`docs/RUNBOOK.md`](docs/RUNBOOK.md) before you need it. It is written for the
3 a.m. version of you.

New to AWS? Start with [`docs/AWS-ACCOUNT-SETUP.md`](docs/AWS-ACCOUNT-SETUP.md).
