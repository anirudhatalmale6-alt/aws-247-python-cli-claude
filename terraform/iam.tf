data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_iam_role" "instance" {
  name = "${var.project_name}-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Lets you open a root shell on the box from the AWS console with no SSH key
# and no inbound firewall hole.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Lets the CloudWatch agent ship logs and custom metrics.
resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Everything else is scoped down by hand - no wildcards on resources.
resource "aws_iam_role_policy" "app" {
  name = "${var.project_name}-app-policy"
  role = aws_iam_role.instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadOwnSecretsOnly"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.claude.arn, aws_secretsmanager_secret.app.arn]
      },
      {
        Sid      = "PublishAlertsToOwnTopicOnly"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = [aws_sns_topic.alerts.arn]
      },
      {
        Sid      = "PublishHeartbeatMetric"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = { "cloudwatch:namespace" = local.metric_namespace }
        }
      },
      {
        Sid      = "DescribeOwnTagsForBootstrap"
        Effect   = "Allow"
        Action   = ["ec2:DescribeTags"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.project_name}-instance-profile"
  role = aws_iam_role.instance.name
}
