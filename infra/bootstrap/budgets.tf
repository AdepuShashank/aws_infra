# -------------------------------------------------------------------- budgets ---
# Cost guardrail: a monthly budget per environment with alerts at the configured
# percentages, published to an SNS topic that has an email subscriber.
#
# NOTE: the SNS email subscription is created as PENDING_CONFIRMATION. AWS sends
# a confirmation email to alert_email and the subscription only becomes active
# after the recipient clicks "Confirm". Until then, budget alerts are silently
# dropped - verify `pending_confirmation = false` in the outputs below.

resource "aws_sns_topic" "alerts" {
  name              = local.alerts_topic_name
  kms_master_key_id = "alias/aws/sns"
  tags              = local.standard_tags
}

data "aws_iam_policy_document" "alerts_topic" {
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
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    # AWS Budgets publishes the breach notification to the topic, but only if the
    # topic policy allows it. Without this statement the budget is created
    # successfully and then silently never notifies anyone.
    sid       = "AllowBudgetsToPublish"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:budgets::${data.aws_caller_identity.current.account_id}:budget/${var.env}/*"]
    }
  }

  statement {
    # CloudWatch alarms route through this topic in the observability layer.
    sid       = "AllowCloudWatchToPublish"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}

resource "aws_sns_topic_subscription" "alert_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email

  depends_on = [aws_sns_topic_policy.alerts]
}

resource "aws_budgets_budget" "monthly" {
  name         = "${local.name_prefix}-monthly-cost"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Tag-scoped budgets are opt-in, because AWS only accepts a tag filter when
  # that tag key has been activated as a Cost Allocation Tag on the account.
  # Activating one is a one-time account-level step
  # (`aws ce update-cost-allocation-tags-status`) that needs
  # ce:UpdateCostAllocationTagsStatus, which this deployment principal does not
  # hold. Without activation AWS rejects the plan with:
  #
  #   InvalidParameterException: ... tag:Env is not in the supported in cost
  #   budget dimension set: [PurchaseType, ... TagKeyValue, ...]
  #
  # With budget_filter_tags empty (the default) the budget covers the whole
  # account, which still exercises the alert path end to end. Note that prod and
  # qa then measure the same account-wide total, so the two budgets are not
  # independent. Populate budget_filter_tags once the tags are activated.
  dynamic "cost_filter" {
    for_each = var.budget_filter_tags

    content {
      name   = "tag:${cost_filter.key}"
      values = [cost_filter.value]
    }
  }



  cost_types {
    include_credit             = true
    include_discount           = true
    include_other_subscription = false
    include_recurring          = true
    include_refund             = true
    include_support            = true
    include_tax                = true
    include_upfront            = true
    use_amortized              = true
    use_blended                = false
  }

  dynamic "notification" {
    for_each = var.budget_threshold_percentages

    content {
      comparison_operator = "GREATER_THAN"
      threshold           = tonumber(notification.value)

      # PERCENTAGE, not ABSOLUTE_VALUE. budget_threshold_percentages holds
      # [80, 100], which are percentages of budget_limit_usd. "ABSOLUTE" is not
      # a value AWS accepts; the enum is PERCENTAGE | ABSOLUTE_VALUE.
      threshold_type = "PERCENTAGE"

      notification_type         = "ACTUAL"
      subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
    }
  }

  tags = local.standard_tags
}
# A tag key that is not an activated Cost Allocation Tag fails at apply time, not
# at plan time, so warn about the configuration being unreachable rather than
# letting someone discover it mid-apply.
check "budget_filter_tags_activated" {
  assert {
    condition     = length(var.budget_filter_tags) == 0
    error_message = "budget_filter_tags requires its tag keys to be activated as AWS Cost Allocation Tags first (aws ce update-cost-allocation-tags-status). Empty it to fall back to an account-wide budget."
  }
}