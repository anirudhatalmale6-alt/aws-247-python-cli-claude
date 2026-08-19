output "instance_id" {
  description = "EC2 instance id - use it to open a shell."
  value       = aws_instance.app.id
}

output "public_ip" {
  description = "Stable public IP of the runner."
  value       = aws_eip.app.public_ip
}

output "open_shell_command" {
  description = "Copy-paste this to get a root shell on the box. No SSH key needed."
  value       = "aws ssm start-session --region ${data.aws_region.current.name} --target ${aws_instance.app.id}"
}

output "tail_app_logs_command" {
  description = "Live-tail the application log from your own machine."
  value       = "aws logs tail ${aws_cloudwatch_log_group.app.name} --follow --region ${data.aws_region.current.name}"
}

output "tail_watchdog_logs_command" {
  description = "Live-tail what the Claude supervisor is doing."
  value       = "aws logs tail ${aws_cloudwatch_log_group.watchdog.name} --follow --region ${data.aws_region.current.name}"
}

output "set_claude_key_command" {
  description = "Run this once to store your Anthropic API key."
  value       = "aws secretsmanager put-secret-value --region ${data.aws_region.current.name} --secret-id ${aws_secretsmanager_secret.claude.name} --secret-string 'sk-ant-YOUR-KEY'"
}

output "set_app_secrets_command" {
  description = "Run this to store your application's own secrets as a JSON object."
  value       = "aws secretsmanager put-secret-value --region ${data.aws_region.current.name} --secret-id ${aws_secretsmanager_secret.app.name} --secret-string '{\"PORTAL_USER\":\"...\",\"PORTAL_PASS\":\"...\"}'"
}

output "dashboard_url" {
  description = "One screen showing uptime, errors and live logs."
  value       = "https://${data.aws_region.current.name}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}

output "sns_topic_arn" {
  description = "Alert topic. Confirm the subscription email before relying on it."
  value       = aws_sns_topic.alerts.arn
}

output "next_steps" {
  value = <<-EOT

    1. Check your inbox for "AWS Notification - Subscription Confirmation" and click
       Confirm subscription. Until you do this you will receive NO alerts.
    2. Store your Anthropic key   -> see output set_claude_key_command
    3. Store your app secrets     -> see output set_app_secrets_command
    4. Watch it come up           -> see output tail_app_logs_command
       First boot takes about 3-4 minutes (OS update + Node + Claude Code install).
    5. Fire a test alert          -> ssm in, then: sudo /opt/appcli/bin/selftest.sh

  EOT
}
