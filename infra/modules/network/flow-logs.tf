# ---------------------------------------------------------------------------
# VPC flow logs (optional)
# ---------------------------------------------------------------------------
# Off by default. Flow Logs to CloudWatch Logs cost roughly USD 0.50 per GB
# ingested, which on a busy cluster is the single most expensive "nice to have"
# in this project. Enable for prod when an incident actually requires it.

locals {
  flow_log_log_group_name = "/aws/vpc/${var.name}/flow-logs"
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name              = local.flow_log_log_group_name
  retention_in_days = var.flow_log_retention_days

  tags = merge(local.tags, { Name = local.flow_log_log_group_name })
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name_prefix        = "${var.name}-flow-logs-"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
  tags               = merge(local.tags, { Name = "${var.name}-flow-logs" })
}

data "aws_iam_policy_document" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]

    resources = ["${aws_cloudwatch_log_group.flow_logs[0].arn}:*"]

    # Flow Logs publishes under a service-owned identity; scoping by account id
    # keeps a compromised principal elsewhere in the account from writing here.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name   = "${var.name}-flow-logs"
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs[0].json
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs[0].arn

  iam_role_arn             = aws_iam_role.flow_logs[0].arn
  max_aggregation_interval = 60

  tags = merge(local.tags, { Name = "${var.name}-flow-logs" })

  depends_on = [aws_iam_role_policy.flow_logs]
}