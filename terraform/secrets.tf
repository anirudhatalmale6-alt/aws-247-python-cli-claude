# Secrets live in Secrets Manager, never in user_data, never on disk in plain text
# and never in git. The instance role can read exactly these two ARNs and nothing else.

resource "aws_secretsmanager_secret" "claude" {
  name                    = "${var.project_name}-claude"
  description             = "ANTHROPIC_API_KEY used by the on-box Claude supervisor"
  recovery_window_in_days = 0 # allows a clean re-apply after destroy
}

resource "aws_secretsmanager_secret_version" "claude" {
  count = var.anthropic_api_key == "" ? 0 : 1

  secret_id     = aws_secretsmanager_secret.claude.id
  secret_string = var.anthropic_api_key

  # If you rotate the key with the CLI, Terraform must not drag it back.
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Free-form JSON bag for whatever YOUR script needs - portal login, schedule id,
# Telegram token, and so on. Written once by you, read at start-up by the service.
resource "aws_secretsmanager_secret" "app" {
  name                    = "${var.project_name}-app"
  description             = "Application secrets exported as environment variables to the CLI"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "app_placeholder" {
  secret_id     = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({ PLACEHOLDER = "replace me with your real key/value pairs" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
