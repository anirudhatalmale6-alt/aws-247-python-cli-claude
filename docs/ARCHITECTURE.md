# Architecture

## The shape of it

```
                    ┌──────────────────────────────────────────────┐
   you ── SSM ─────▶│  EC2 t3.micro  (Amazon Linux 2023)           │
   (no SSH port)    │                                              │
                    │  systemd: appcli.service                     │
                    │    └─ run-app.sh ─▶ your Python CLI          │
                    │         Restart=always, RestartSec=10        │
                    │                                              │
                    │  systemd timer: appcli-watchdog (every 60s)  │
                    │    └─ watchdog.sh                            │
                    │         ├─ heartbeat metric                  │
                    │         ├─ SNS alert on failure              │
                    │         ├─ claude -p  (diagnosis)            │
                    │         └─ restart / crash-loop hold         │
                    │                                              │
                    │  CloudWatch agent ─▶ log shipping            │
                    └────────┬──────────────────────┬──────────────┘
                             │                      │
                    ┌────────▼────────┐    ┌────────▼─────────┐
                    │ CloudWatch Logs │    │  Secrets Manager │
                    │ CloudWatch Alarm│    │  claude key      │
                    └────────┬────────┘    │  app secrets     │
                             │             └──────────────────┘
                    ┌────────▼────────┐
                    │   SNS topic     │──▶ your email / SMS
                    └─────────────────┘
```

## Why EC2 and not Lambda

Lambda caps out at 15 minutes per invocation and has no persistent process. A CLI that
holds a session, keeps a browser open, or polls in a loop does not fit that model — you
would end up rewriting it as a stateless function plus a scheduler plus somewhere to
keep the session, and you would still be paying for a NAT gateway to give it a stable
outbound IP.

ECS Fargate would work but costs more than a t3.micro for a single always-on task, and
adds a container registry and a task definition to maintain for no benefit at this size.

One small EC2 instance is the right answer for one long-running process. If the workload
ever grows to many parallel jobs, the migration path is ECS — but that is a different
problem than the one being solved here.

## Why four layers of recovery

Each layer catches something the one below it structurally cannot:

| Layer | Catches | Reaction time |
|---|---|---|
| `systemd Restart=always` | process exits, crashes, OOM kill | 10s |
| `watchdog.sh` (60s timer) | crash loops, why it failed, service that will not start | 60s |
| CloudWatch heartbeat alarm | the whole instance being gone | 2 min |
| EC2 status-check alarm | hardware/kernel fault → auto-reboot | ~2 min |

The heartbeat alarm is the important one and it is easy to get wrong. It uses
`treat_missing_data = "breaching"`, so **absence of data is itself the alarm**. An alarm
that only fires on a reported failure cannot tell you about a box that stopped being
able to report anything.

## How the alerting actually meets "within one minute"

Two paths, deliberately:

- **`notify.sh` publishes straight to SNS** the instant the watchdog sees a problem —
  under a second, with the log tail already in the message body. This is the path that
  meets the requirement.
- **CloudWatch alarms** are the backstop, and they are slower (a metric filter has ~1
  minute of latency, plus the alarm evaluation period). They exist to catch what the box
  cannot report about itself.

Relying on the alarms alone would technically pass a 1-minute test only on a good day.
Relying on the box alone would miss the box dying. You want both.

## Why the watchdog stops restarting

`systemd` with `StartLimitIntervalSec=0` will restart forever, which is correct for a
transient fault and wrong for a broken client hammering a remote endpoint. After 6
failures in 30 minutes the watchdog holds, alerts, and waits for a human. Being down and
loud beats being broken and noisy.

## Secrets

Nothing sensitive is in git, in `user_data`, or on disk:

- **Anthropic key** → Secrets Manager, read fresh by the watchdog on each failure.
- **App secrets** → Secrets Manager, read by `run-app.sh` at start-up and exported into
  the process environment only.
- **No IAM access keys on the instance** — it uses an instance role, so there is no
  long-lived credential to leak.
- **IMDSv2 required**, which closes the SSRF-to-credential-theft path.
- **No inbound ports at all** by default. Management is via SSM Session Manager, which
  is an outbound connection from the instance.

The IAM policy grants `secretsmanager:GetSecretValue` on exactly two ARNs and
`sns:Publish` on exactly one topic. No resource wildcards.

## Redeploy path

`git push` → `deploy.sh` on the box → pull, reinstall deps, restart, verify.

If the service does not come back within 15 seconds, the previous release directory is
restored and restarted, and you get an email saying so. The design assumption is that a
bad push will happen eventually, and it should cost you a rollback rather than an outage.

## What this design does not do

Stated plainly so there are no surprises:

- **It is a single instance.** If the AZ fails, you are down until the instance is
  rebuilt (~5 minutes, one `terraform apply`). True HA for a stateful single-session
  process is a much bigger piece of work and rarely worth it for this workload.
- **It does not scale horizontally.** Nothing here coordinates multiple copies of the
  CLI, and running two copies of a session-holding client usually causes problems rather
  than solving them.
- **The EC2 public IP is an AWS datacentre address.** Any remote service that blocks
  cloud IP ranges will treat this box differently from your laptop. That is a property
  of the target service, not something the infrastructure can fix — test it before
  committing to the architecture.
