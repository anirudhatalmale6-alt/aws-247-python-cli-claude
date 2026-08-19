# Setting up the AWS account from scratch

Follow this once. About 20 minutes, most of it waiting for verification.

---

## 1. Create the account

Go to <https://portal.aws.amazon.com/billing/signup>.

- Use an email address you control long-term. This becomes the **root account** and it
  is painful to change later.
- You need a payment card. AWS charges about $1 to verify it and refunds it.
- Phone verification is automated — it calls or texts a PIN.
- Choose the **Basic support plan** (free). You can upgrade later.

Account activation usually takes a few minutes but can take a few hours. You will get
an email when it is ready.

## 2. Lock down the root account — do this before anything else

The root account can delete everything and cannot be restricted. Treat it like the key
to a safe: used once, then put away.

1. Sign in as root.
2. Top-right menu → **Security credentials**.
3. **Multi-factor authentication (MFA)** → Assign MFA device → Authenticator app.
   Scan the QR with Google Authenticator, Authy, or your password manager.
4. Under **Access keys**, if any exist, **delete them**. Root access keys should never
   exist. A leaked one is a total account compromise.

Then sign out of root and do not use it again except for billing changes.

## 3. Create your day-to-day admin user

Still signed in as root, one last time:

1. Go to **IAM** → **Users** → **Create user**.
2. Name: `admin`. Tick **Provide user access to the AWS Management Console**.
3. Permissions → **Attach policies directly** → `AdministratorAccess`.
4. Create. **Save the sign-in URL, username and password.**
5. Sign out of root. Sign in as `admin`. Enable MFA on this user too.

## 4. Create an access key for Terraform

As `admin`: IAM → Users → `admin` → **Security credentials** → **Create access key** →
choose **Command Line Interface (CLI)**.

You get an **Access key ID** and a **Secret access key**. The secret is shown exactly
once — copy it now.

> Never paste these into chat, a ticket, or a git repo. If one leaks, delete it in the
> same console screen and create a new one; that instantly invalidates the old one.

## 5. Install and configure the AWS CLI

**Windows** — download and run the installer from
<https://awscli.amazonaws.com/AWSCLIV2.msi>

**macOS** — `brew install awscli`

**Linux** —
```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscli.zip
unzip awscli.zip && sudo ./aws/install
```

Then:

```bash
aws configure
# AWS Access Key ID     : from step 4
# AWS Secret Access Key : from step 4
# Default region name   : eu-west-1   (or whichever you picked)
# Default output format : json

aws sts get-caller-identity     # should print your account id and the admin user ARN
```

That last command succeeding is the real test that everything is wired up.

## 6. Install Terraform

<https://developer.hashicorp.com/terraform/install> — it is a single binary.

```bash
terraform version
```

## 7. Get an Anthropic API key

For the Claude supervisor on the box:

1. <https://console.anthropic.com> → sign up.
2. **Settings → API keys → Create key**. Copy it (starts `sk-ant-`).
3. Add a small amount of credit under **Billing**. $5 goes a very long way here, because
   Claude is only invoked when something has actually broken.
4. Set a **monthly spend limit** while you are in there. Belt and braces.

Do not put this key in `terraform.tfvars` — store it after apply, with the command
`terraform output -raw set_claude_key_command` prints. That keeps it out of the
Terraform state file.

## 8. Which region?

Pick the one nearest to you for lower latency and easier troubleshooting:

| Where you are | Region |
|---|---|
| India | `ap-south-1` (Mumbai) |
| Europe / UK | `eu-west-1` (Ireland) or `eu-west-2` (London) |
| US East | `us-east-1` (N. Virginia) |
| US West | `us-west-2` (Oregon) |
| Middle East | `me-central-1` (UAE) |
| Singapore / SE Asia | `ap-southeast-1` |

Set it as `aws_region` in `terraform.tfvars`. Moving region later means a rebuild, so
choose once.

## 9. Now run the deployment

Back to the [README](../README.md), "Quick start".

---

## Keeping the bill near zero

- The first 12 months include 750 hours/month of `t3.micro` — that is one instance
  running 24/7, free.
- After that, expect **$8–15/month** all in.
- The stack creates a **billing alarm** at `$20/month` by default (`monthly_budget_usd`).
  You get an email before anything gets expensive.
- Also switch on **Billing → Budgets → Zero-spend budget** in the console — it is free
  and it is the single best guard against a surprise.
- `terraform destroy` removes every billable resource in one go.
