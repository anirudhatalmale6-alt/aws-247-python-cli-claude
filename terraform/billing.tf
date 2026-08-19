# Billing metrics only exist in us-east-1, regardless of where the stack runs.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
    }
  }
}

variable "monthly_budget_usd" {
  description = "Email an alert if the estimated AWS bill for the month passes this. Set 0 to disable."
  type        = number
  default     = 20
}

resource "aws_sns_topic" "billing" {
  count    = var.monthly_budget_usd > 0 ? 1 : 0
  provider = aws.us_east_1
  name     = "${var.project_name}-billing-alerts"
}

resource "aws_sns_topic_subscription" "billing_email" {
  count     = var.monthly_budget_usd > 0 ? 1 : 0
  provider  = aws.us_east_1
  topic_arn = aws_sns_topic.billing[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "billing" {
  count    = var.monthly_budget_usd > 0 ? 1 : 0
  provider = aws.us_east_1

  alarm_name          = "${var.project_name}-monthly-spend"
  alarm_description   = "Estimated AWS charges for this month exceeded $${var.monthly_budget_usd}."
  namespace           = "AWS/Billing"
  metric_name         = "EstimatedCharges"
  statistic           = "Maximum"
  period              = 21600 # 6h - the fastest AWS publishes billing metrics
  evaluation_periods  = 1
  threshold           = var.monthly_budget_usd
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = { Currency = "USD" }

  alarm_actions = [aws_sns_topic.billing[0].arn]
}
