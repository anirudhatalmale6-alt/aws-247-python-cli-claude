variable "project_name" {
  description = "Short name used to prefix every AWS resource. Lowercase, no spaces."
  type        = string
  default     = "visa-cli"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,24}$", var.project_name))
    error_message = "project_name must be 3-24 chars, lowercase letters, digits and hyphens only."
  }
}

variable "aws_region" {
  description = "AWS region to deploy into. Pick the one closest to you."
  type        = string
  default     = "eu-west-1"
}

variable "instance_type" {
  description = "EC2 instance size. t3.micro is free-tier eligible for the first 12 months."
  type        = string
  default     = "t3.micro"
}

variable "root_volume_gb" {
  description = "Root EBS volume size in GB. 30 GB is the free-tier limit."
  type        = number
  default     = 20
}

# ---------------------------------------------------------------------------
# Alerting
# ---------------------------------------------------------------------------

variable "alert_email" {
  description = "Email address that receives all alerts. AWS sends a confirmation link you MUST click."
  type        = string

  validation {
    condition     = can(regex("^[^@ ]+@[^@ ]+\\.[^@ ]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}

variable "alert_sms" {
  description = "Optional E.164 mobile number for SMS alerts, e.g. +919876543210. Leave empty to disable."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Application
# ---------------------------------------------------------------------------

variable "app_repo_url" {
  description = <<-EOT
    HTTPS git URL of the repository holding YOUR Python CLI.
    Leave empty to deploy the bundled demo script instead - useful for proving the
    plumbing works before your real code is ready. For a private repo, put a
    token-bearing URL in the app_git_token variable instead of hard-coding it here.
  EOT
  type        = string
  default     = ""
}

variable "app_branch" {
  description = "Branch of app_repo_url to deploy."
  type        = string
  default     = "main"
}

variable "app_entrypoint" {
  description = "Command used to start your CLI, relative to the repo root. Example: 'python -u main.py --watch'."
  type        = string
  default     = "python -u main.py"
}

variable "app_git_token" {
  description = "Optional GitHub personal access token, only needed if app_repo_url is private."
  type        = string
  default     = ""
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Claude supervisor
# ---------------------------------------------------------------------------

variable "anthropic_api_key" {
  description = <<-EOT
    Anthropic API key for the on-box Claude supervisor.
    Leave empty and set it after apply with:
      aws secretsmanager put-secret-value --secret-id <project>-claude --secret-string 'sk-ant-...'
    Setting it here means the value lands in terraform.tfstate, so prefer the CLI route
    unless your state file is encrypted and private.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "claude_model" {
  description = "Model the supervisor uses. 'sonnet' is the sensible default for cost; 'opus' for hard failures."
  type        = string
  default     = "sonnet"
}

variable "claude_autofix" {
  description = <<-EOT
    false (default): on a crash Claude diagnoses, writes a report and restarts the service.
    true: Claude is additionally allowed to EDIT your code and commit the fix to a
    'claude-autofix' branch. Never pushed to main. Only turn this on once you trust it.
  EOT
  type        = bool
  default     = false
}

variable "watchdog_interval_minutes" {
  description = "How often the watchdog checks the service and publishes its heartbeat."
  type        = number
  default     = 1
}

# ---------------------------------------------------------------------------
# Bootstrap / access
# ---------------------------------------------------------------------------

variable "bootstrap_repo_url" {
  description = "Public git URL of THIS repository - the instance clones it at boot to install itself."
  type        = string
  default     = "https://github.com/anirudhatalmale6-alt/aws-247-python-cli-claude.git"
}

variable "bootstrap_branch" {
  description = "Branch of the bootstrap repo to install from."
  type        = string
  default     = "main"
}

variable "ssh_key_name" {
  description = <<-EOT
    Optional name of an existing EC2 key pair for SSH.
    Leave empty - the default - and you get in via SSM Session Manager instead,
    which needs no key, no open port 22 and no public key management.
  EOT
  type        = string
  default     = ""
}

variable "ssh_ingress_cidr" {
  description = "CIDR allowed to reach port 22. Only used when ssh_key_name is set. Never use 0.0.0.0/0."
  type        = string
  default     = "127.0.0.1/32"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention. 30 days keeps costs near zero."
  type        = number
  default     = 30
}
