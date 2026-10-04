# ---------------------------------------------------------------------------
# Ops alert topic
# ---------------------------------------------------------------------------
# Separate from infra/bootstrap's <project>-<env>-alerts on purpose:
#
#   * bootstrap's topic policy lives in a bootstrap state. Adding a statement to it
#     from 60-ops would either mean managing the same topic twice or editing
#     bootstrap to accept the change, and both are worse than a second topic.
#   * Budget alerts and cluster alarms are different urgencies. Being able to
#     leave the budget address subscribed and take yourself off the cluster one
#     is worth one topic.
#
# The topic policy is not decoration. CloudWatch silently discards an alarm
# notification it is not authorised to publish, so a topic with no
# AllowCloudWatchToPublish statement produces alarms that stay green forever -
# which is the same as having no alarms.

resource "aws_sns_topic" "ops_alerts" {
  name              = module.naming["alerts_topic"].full_name
  kms_master_key_id = var.sns_kms_master_key_id

  tags = merge(local.resource_tags["alerts_topic"], { Name = module.naming["alerts_topic"].full_name })
}

data "aws_iam_policy_document" "ops_alerts" {
  statement {
    sid    = "AllowAccountOperators"
    effect = "Allow"

    actions = [
      "SNS:Publish",
      "SNS:Subscribe",
      "SNS:ListSubscriptionsByTopic",
      "SNS:GetTopicAttributes",
      "SNS:SetTopicAttributes",
    ]

    resources = [aws_sns_topic.ops_alerts.arn]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    # Without this the alarms exist, evaluate correctly, and never reach anyone.
    sid       = "AllowCloudWatchToPublish"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.ops_alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
  }
}

resource "aws_sns_topic_policy" "ops_alerts" {
  arn    = aws_sns_topic.ops_alerts.arn
  policy = data.aws_iam_policy_document.ops_alerts.json
}

# Deliberately created as PENDING_CONFIRMATION. Terraform cannot click the link
# AWS emails, so the subscription is "not working" until a human does. That is
# still the right default: a topic with an unconfirmed subscription that someone
# notices and confirms beats a topic with no subscription and nobody asking.
resource "aws_sns_topic_subscription" "alert_email" {
  topic_arn = aws_sns_topic.ops_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email

  depends_on = [aws_sns_topic_policy.ops_alerts]
}

data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}
