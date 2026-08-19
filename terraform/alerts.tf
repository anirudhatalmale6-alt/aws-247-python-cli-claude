locals {
  metric_namespace = "${var.project_name}/watchdog"
}

resource "aws_sns_topic" "alerts" {
  name         = "${var.project_name}-alerts"
  display_name = var.project_name # SMS sender label, max 11 chars is safest
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
  # NOTE: AWS emails a confirmation link. Until you click it you get NO alerts.
}

resource "aws_sns_topic_subscription" "sms" {
  count = var.alert_sms == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "sms"
  endpoint  = var.alert_sms
}

# ---------------------------------------------------------------------------
# Log groups
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.project_name}/app"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "watchdog" {
  name              = "/${var.project_name}/watchdog"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "system" {
  name              = "/${var.project_name}/system"
  retention_in_days = var.log_retention_days
}

# ---------------------------------------------------------------------------
# Alarm 1 - anything that smells like an error in the application log.
#
# The filter pattern is a set of OR'd quoted terms: CloudWatch treats
# ?"a" ?"b" as "line contains a OR b". Case matters, so we cover the
# common casings Python actually emits.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_metric_filter" "app_errors" {
  name           = "${var.project_name}-app-errors"
  log_group_name = aws_cloudwatch_log_group.app.name
  pattern        = "?\"Traceback (most recent call last)\" ?\"ERROR\" ?\"CRITICAL\" ?\"Exception\" ?\"FATAL\""

  metric_transformation {
    name          = "AppErrors"
    namespace     = local.metric_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "app_errors" {
  alarm_name          = "${var.project_name}-app-errors"
  alarm_description   = "The Python CLI logged an error or traceback."
  namespace           = local.metric_namespace
  metric_name         = "AppErrors"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ---------------------------------------------------------------------------
# Alarm 2 - the heartbeat.
#
# The watchdog pushes ServiceUp=1 every minute while the CLI is running, and
# ServiceUp=0 the moment it is not. If the whole instance dies, no datapoint
# arrives at all - which is why treat_missing_data is "breaching". This is the
# alarm that catches a hard box failure, not just an application crash.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "service_down" {
  alarm_name          = "${var.project_name}-service-down"
  alarm_description   = "The CLI is not running, or the instance stopped reporting entirely."
  namespace           = local.metric_namespace
  metric_name         = "ServiceUp"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ---------------------------------------------------------------------------
# Alarm 3 - EC2 hardware/OS health, with automatic reboot.
# The arn:aws:automate:...:ec2:reboot action is a built-in AWS action; it costs
# nothing and needs no Lambda.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "status_check" {
  alarm_name          = "${var.project_name}-status-check-failed"
  alarm_description   = "EC2 status check failed - rebooting the instance automatically."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = { InstanceId = aws_instance.app.id }

  alarm_actions = [
    aws_sns_topic.alerts.arn,
    "arn:aws:automate:${data.aws_region.current.name}:ec2:reboot",
  ]
}

# ---------------------------------------------------------------------------
# Alarm 4 - disk filling up. Logs and Claude transcripts are the usual culprit.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "disk" {
  alarm_name          = "${var.project_name}-disk-almost-full"
  alarm_description   = "Root volume above 85% used."
  namespace           = "CWAgent"
  metric_name         = "disk_used_percent"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = aws_instance.app.id
    path       = "/"
    fstype     = "xfs"
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

# ---------------------------------------------------------------------------
# Dashboard - one screen that answers "is it alive and what has it been doing".
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = var.project_name

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title   = "Service up (1 = running)"
          region  = data.aws_region.current.name
          view    = "timeSeries"
          stat    = "Minimum"
          period  = 60
          yAxis   = { left = { min = 0, max = 1 } }
          metrics = [[local.metric_namespace, "ServiceUp"]]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title   = "Application errors per minute"
          region  = data.aws_region.current.name
          view    = "timeSeries"
          stat    = "Sum"
          period  = 60
          metrics = [[local.metric_namespace, "AppErrors"], [local.metric_namespace, "Restarts"]]
        }
      },
      {
        type = "log", x = 0, y = 6, width = 24, height = 8
        properties = {
          title  = "Latest application log"
          region = data.aws_region.current.name
          query  = "SOURCE '${aws_cloudwatch_log_group.app.name}' | fields @timestamp, @message | sort @timestamp desc | limit 100"
        }
      },
      {
        type = "log", x = 0, y = 14, width = 24, height = 8
        properties = {
          title  = "Watchdog / Claude supervisor"
          region = data.aws_region.current.name
          query  = "SOURCE '${aws_cloudwatch_log_group.watchdog.name}' | fields @timestamp, @message | sort @timestamp desc | limit 100"
        }
      },
    ]
  })
}
