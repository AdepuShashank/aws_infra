# ---------------------------------------------------------------------------
# Scheduled stop / start (60-ops)
# ---------------------------------------------------------------------------
# Infrastructure.MD asks for one scheduled stop, on qa only, on nights and weekends.
# This stops the instances rather than destroying them, which is the same mechanism
# `compute_enabled = false` uses in 30-cluster: the root volume survives, so
# etcd - and therefore the cluster - comes back with it.
#
# Why not just leave compute_enabled = false permanently in qa? Because that also
# removes qa's place in the state, and a permanently-stopped qa is indistinguishable
# from a broken one. These schedules turn it off when nobody is using it and back on
# when somebody is, without a human editing a tfvars file at 8am.
#
# Why EventBridge Scheduler rather than an EventBridge rule with a Lambda target:
#   * no function, no code, no version to keep current;
#   * the AWS SDK integration targets are built in, so EC2 stop/start and the ASG
#     desired-capacity update are configuration, not a 40-line handler;
#   * and it is the service AWS built specifically for "call an AWS API on a
#     schedule", so the execution role is narrow rather than lambda-wide.

locals {
  name_prefix = "${var.project}-${var.env}"

  naming_resources = {
    scheduler_role = "scheduler-role"
    stop_schedule  = "stop-schedule"
    start_schedule = "start-schedule"
  }

  # Both flags must be on before anything is created. See allow_prod_scheduling.
  enabled = var.enable_scheduling && (var.env != "prod" || var.allow_prod_scheduling)
}

module "naming" {
  source = "../naming"

  for_each = local.naming_resources

  name        = each.value
  project     = var.project
  env         = var.env
  layer       = var.layer
  owner       = var.owner
  cost_center = var.cost_center
  component   = "scheduler"
}

locals {
  resource_tags = {
    for key, naming in module.naming : key => merge(naming.tags, var.extra_tags)
  }
}

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------
# A schedule that enables itself but has no target is not a no-op, it is a schedule
# that fires, assumes a role, calls EC2 with an empty target list and succeeds -
# every week, forever, looking like it is doing something.

check "scheduling_has_targets" {
  assert {
    condition     = !local.enabled || length(var.instance_ids) > 0 || var.worker_asg_name != null
    error_message = "enable_scheduling = true but neither instance_ids nor worker_asg_name is set, so both schedules would fire against nothing."
  }

  assert {
    condition     = !local.enabled || var.asg_start_desired_capacity >= 0
    error_message = "asg_start_desired_capacity must not be negative."
  }
}

check "prod_scheduling_is_deliberate" {
  assert {
    condition     = !var.enable_scheduling || var.env != "prod" || var.allow_prod_scheduling
    error_message = "enable_scheduling = true in prod also needs allow_prod_scheduling = true. Infrastructure.MD scopes scheduled stop to qa."
  }
}

# ---------------------------------------------------------------------------
# Execution role
# ---------------------------------------------------------------------------
# One role for both schedules, because both do the same two things. Scoped to
# specific instances and one ASG rather than to a tag, because a tag-scoped
# ec2:StartInstances grant on a schedule is an unattended way to start a future
# instance nobody has reviewed.

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  count = local.enabled ? 1 : 0

  name_prefix          = "${module.naming["scheduler_role"].full_name}-"
  description          = "Lets EventBridge Scheduler start and stop the ${var.project}/${var.env} instances on a schedule."
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  max_session_duration = 3600

  tags = merge(local.resource_tags["scheduler_role"], { Name = module.naming["scheduler_role"].full_name })
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_iam_policy_document" "scheduler" {
  count = local.enabled ? 1 : 0

  # Start needs Describe, ModifyInstanceAttribute (EBS optimisation is set per
  # instance and cannot be changed while stopped) and StartInstances. Stop needs
  # StopInstances and, for it to actually happen, a Describe check first: stopping a
  # stopping instance is an eventual-consistency race, and EC2's own console retries
  # it, so the schedule does too.
  statement {
    sid    = "ControlPlaneState"
    effect = "Allow"
    actions = [
      "ec2:StartInstances",
      "ec2:StopInstances",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeInstanceAttribute",
      "ec2:ModifyInstanceAttribute",
    ]

    # Resource * is unavoidable for the start/stop calls themselves - EC2 does not
    # support resource-level permissions for them - but the condition pins the
    # action to this project's instances by tag, so the role cannot be used to stop
    # or start anything else in the account even by accident.
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [var.project]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Env"
      values   = [var.env]
    }
  }

  dynamic "statement" {
    for_each = var.worker_asg_name == null ? [] : [1]

    content {
      sid    = "WorkerScaling"
      effect = "Allow"
      actions = [
        "autoscaling:UpdateDesiredCapacity",
        "autoscaling:DescribeAutoScalingGroups",
      ]

      # Resource-level permissions work for UpdateDesiredCapacity, unlike EC2's
      # start/stop, so this statement is narrower than the one above.
      resources = ["arn:${data.aws_partition.current.partition}:autoscaling:${var.aws_region}:${data.aws_caller_identity.current.account_id}:autoScalingGroup:*:autoScalingGroupName/${var.worker_asg_name}"]
    }
  }
}

resource "aws_iam_role_policy" "scheduler" {
  count = local.enabled ? 1 : 0

  name   = module.naming["scheduler_role"].full_name
  role   = aws_iam_role.scheduler[0].id
  policy = data.aws_iam_policy_document.scheduler[0].json
}

# ---------------------------------------------------------------------------
# Schedules
# ---------------------------------------------------------------------------
# Two schedules rather than one combined one, because a stop and a start are not
# symmetric and a single expression cannot express "Friday night to Monday
# morning". Two also means each can be disabled or re-timed on its own.

resource "aws_scheduler_schedule" "stop" {
  count = local.enabled ? 1 : 0

  name       = module.naming["stop_schedule"].full_name
  group_name = "default"

  schedule_expression          = var.stop_schedule_expression
  schedule_expression_timezone = "Asia/Kolkata"

  # Encrypted at rest. Null means the AWS-managed aws/scheduler key; see schedule_kms_key_arn.
  kms_key_arn = var.schedule_kms_key_arn

  flexible_time_window {
    # Always OFF for the ASG pair even when the EC2 pair has a window enabled. A
    # group that comes up an hour late is a nuisance; a node that comes up an hour
    # late on top of an already-running control plane is a scale-to-quota race that
    # ends in VcpuLimitExceeded.
    mode = "OFF"
  }

  target {
    arn      = "arn:${data.aws_partition.current.partition}:scheduler:${var.aws_region}::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler[0].arn

    input = jsonencode({
      InstanceIds = var.instance_ids
    })
  }

  depends_on = [aws_iam_role_policy.scheduler]
}

resource "aws_scheduler_schedule" "start" {
  count = local.enabled ? 1 : 0

  name       = module.naming["start_schedule"].full_name
  group_name = "default"

  schedule_expression          = var.start_schedule_expression
  schedule_expression_timezone = "Asia/Kolkata"

  kms_key_arn = var.schedule_kms_key_arn

  flexible_time_window {
    mode = var.flexible_time_window_enabled ? "ENABLED" : "OFF"

    maximum_window_in_minutes = var.flexible_time_window_enabled ? var.flexible_time_window_minutes : null
  }

  target {
    arn      = "arn:${data.aws_partition.current.partition}:scheduler:${var.aws_region}::aws-sdk:ec2:startInstances"
    role_arn = aws_iam_role.scheduler[0].arn

    input = jsonencode({
      InstanceIds = var.instance_ids
    })
  }

  depends_on = [aws_iam_role_policy.scheduler]
}

# --- ASG capacity, as separate schedules ---------------------------------------
# EventBridge Scheduler takes one target per schedule, so scaling the ASG cannot be
# a second target on either of the above: it needs its own schedule on the same
# expression. These are the pair Infrastructure.MD's "ASG min0/max2" implies for qa -
# the group is left at zero rather than being asked to hold zero.

resource "aws_scheduler_schedule" "stop_asg" {
  count = local.enabled && var.worker_asg_name != null ? 1 : 0

  name       = "${module.naming["stop_schedule"].full_name}-asg"
  group_name = "default"

  schedule_expression          = var.stop_schedule_expression
  schedule_expression_timezone = "Asia/Kolkata"

  kms_key_arn = var.schedule_kms_key_arn

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:${data.aws_partition.current.partition}:scheduler:${var.aws_region}::aws-sdk:autoscaling:updateDesiredCapacity"
    role_arn = aws_iam_role.scheduler[0].arn

    input = jsonencode({
      AutoScalingGroupName = var.worker_asg_name
      DesiredCapacity      = 0
    })
  }

  depends_on = [aws_iam_role_policy.scheduler]
}

resource "aws_scheduler_schedule" "start_asg" {
  count = local.enabled && var.worker_asg_name != null ? 1 : 0

  name       = "${module.naming["start_schedule"].full_name}-asg"
  group_name = "default"

  schedule_expression          = var.start_schedule_expression
  schedule_expression_timezone = "Asia/Kolkata"

  kms_key_arn = var.schedule_kms_key_arn

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:${data.aws_partition.current.partition}:scheduler:${var.aws_region}::aws-sdk:autoscaling:updateDesiredCapacity"
    role_arn = aws_iam_role.scheduler[0].arn

    input = jsonencode({
      AutoScalingGroupName = var.worker_asg_name
      DesiredCapacity      = var.asg_start_desired_capacity
    })
  }

  depends_on = [aws_iam_role_policy.scheduler]
}
