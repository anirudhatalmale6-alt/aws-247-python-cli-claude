data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.instance.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  key_name               = var.ssh_key_name == "" ? null : var.ssh_key_name

  root_block_device {
    volume_size           = var.root_volume_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  # IMDSv2 only - blocks the SSRF-to-credential-theft class of attack outright.
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  monitoring = true

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    project_name       = var.project_name
    aws_region         = data.aws_region.current.name
    bootstrap_repo_url = var.bootstrap_repo_url
    bootstrap_branch   = var.bootstrap_branch
    app_repo_url       = var.app_repo_url
    app_branch         = var.app_branch
    app_entrypoint     = var.app_entrypoint
    app_git_token      = var.app_git_token
    claude_secret_id   = aws_secretsmanager_secret.claude.name
    app_secret_id      = aws_secretsmanager_secret.app.name
    sns_topic_arn      = aws_sns_topic.alerts.arn
    metric_namespace   = local.metric_namespace
    claude_model       = var.claude_model
    claude_autofix     = var.claude_autofix ? "true" : "false"
    watchdog_interval  = var.watchdog_interval_minutes
    log_group_app      = aws_cloudwatch_log_group.app.name
    log_group_watchdog = aws_cloudwatch_log_group.watchdog.name
    log_group_system   = aws_cloudwatch_log_group.system.name
  })

  tags = { Name = "${var.project_name}-runner" }

  depends_on = [
    aws_iam_role_policy.app,
    aws_iam_role_policy_attachment.ssm,
    aws_iam_role_policy_attachment.cw_agent,
    aws_cloudwatch_log_group.app,
    aws_cloudwatch_log_group.watchdog,
    aws_cloudwatch_log_group.system,
    aws_secretsmanager_secret_version.app_placeholder,
  ]
}

# A stable public IP so the address never changes across reboots or rebuilds.
resource "aws_eip" "app" {
  domain   = "vpc"
  instance = aws_instance.app.id
  tags     = { Name = "${var.project_name}-eip" }

  depends_on = [aws_internet_gateway.main]
}
