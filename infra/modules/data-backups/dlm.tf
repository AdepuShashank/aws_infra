# ---------------------------------------------------------------------------
# Data Lifecycle Manager: EBS snapshot retention
# ---------------------------------------------------------------------------
# The postgres backup path produces EBS snapshots, and every
# `aws ec2 create-snapshot` a human runs while debugging a node is another one.
# Nothing deletes them. On a throwaway portfolio environment that is not a bill; on
# anything real it is unbounded growth in a resource with no lifecycle of its own.
#
# DLM is the right tool rather than a scheduled script because it deletes by tag and
# age on AWS's side: no instance to run it, no credentials in the cluster, and it
# keeps working while every node is stopped - which is most of the time here.
#
# Scope is deliberately narrow: only snapshots carrying this environment's Env tag.
# A snapshot with no Env tag is invisible to this policy, so a snapshot created by
# something outside Terraform is never deleted by it. That is the visible failure
# rather than the invisible one.

data "aws_iam_policy_document" "dlm_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  count = var.dlm_enabled ? 1 : 0

  name_prefix          = "${module.naming["dlm_role"].full_name}-"
  description          = "Lets Data Lifecycle Manager delete ${var.project}/${var.env} EBS snapshots past their retention."
  assume_role_policy   = data.aws_iam_policy_document.dlm_assume.json
  max_session_duration = 3600

  tags = merge(local.resource_tags["dlm_role"], { Name = module.naming["dlm_role"].full_name })
}

data "aws_iam_policy_document" "dlm" {
  count = var.dlm_enabled ? 1 : 0

  # Delete is the only action a policy with no copy or AMI actions needs.
  statement {
    sid    = "DeleteExpiredSnapshots"
    effect = "Allow"
    actions = [
      "dlm:DeleteSnapshot",
    ]
    resources = ["*"]
  }

  # Describe is what lets the policy decide what is in scope.
  statement {
    sid    = "DescribeSnapshots"
    effect = "Allow"
    actions = [
      "ec2:DescribeSnapshots",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "dlm" {
  count = var.dlm_enabled ? 1 : 0

  name   = module.naming["dlm_role"].full_name
  role   = aws_iam_role.dlm[0].id
  policy = data.aws_iam_policy_document.dlm[0].json
}

resource "aws_dlm_lifecycle_policy" "ebs" {
  count = var.dlm_enabled ? 1 : 0

  # Letters, digits, spaces and hyphens only. The DLM API rejects a description
  # containing "." or ":" with an opaque
  #   invalid value for description (see .../dlm/create-lifecycle-policy.html)
  # at plan time, verified by trying each character against ap-south-1. The provider
  # links to the CLI reference, which does not document the restriction - so this
  # description has to stay in the reduced character set, and the sentence that would
  # otherwise be the natural place to put the reason cannot be written here as a
  # comment either, because a comment is fine but the description is not.
  description        = "${module.naming["dlm_policy"].full_name} - delete ${var.env} EBS snapshots older than ${var.dlm_retention_days} days"
  execution_role_arn = aws_iam_role.dlm[0].arn

  # Explicit rather than left to the default. A policy that exists but is disabled
  # reports itself as a policy in the console and silently never deletes anything.
  state = "ENABLED"

  policy_details {
    # EBS_SNAPSHOT_MANAGEMENT is the default and is the only one of the three that
    # applies here. The other two - IMAGE_MANAGEMENT and EVENT_BASED_POLICY - take a
    # completely different shape (the second requires an `action` block, which is
    # why the schema insists on one if policy_type is set to it).
    policy_type = "EBS_SNAPSHOT_MANAGEMENT"

    # VOLUME, not EBS_SNAPSHOT. In this policy language the resource being managed
    # is the volume whose snapshots are managed, which is counter-intuitive enough
    # to be worth stating: the same string in the old schema meant the snapshots.
    resource_types = ["VOLUME"]

    # The only filter. A snapshot with no Env tag is never touched, so a snapshot
    # tagged by mistake in the other environment cannot be deleted from here.
    target_tags = {
      Env = var.env
    }

    parameters {
      # Root-volume snapshots are how a stopped node's data survives a
      # `terraform destroy`, and they carry the same Env tag as everything else.
      # Deleting them on a schedule would quietly destroy the thing the pause
      # mechanism exists to preserve.
      exclude_boot_volume = true
    }

    schedule {
      name = "${module.naming["dlm_policy"].full_name}-daily"

      create_rule {
        # The sweep interval, not the retention. It bounds how long an expired
        # snapshot can survive before something looks at it.
        interval      = var.dlm_interval_hours
        interval_unit = "HOURS"

        # Required alongside interval. 00:17 rather than 00:00 so this policy's
        # evaluation does not land in the same minute as every other schedule in
        # the account and compete for the same throttling window.
        times = ["00:17"]
      }

      retain_rule {
        # interval rather than count: DLM's `count` only accepts 2-14, and this
        # project's retention is expressed in days and may be changed.
        interval      = var.dlm_retention_days
        interval_unit = "DAYS"
      }

      # Marks the snapshot as DLM-managed, which is how one of these is told apart
      # from a manual one at a glance in the console.
      tags_to_add = {
        ManagedByDLM = var.project
      }

      # The Env tag this policy filters on has to survive onto the snapshot DLM
      # creates, or the next evaluation does not see its own output.
      copy_tags = true
    }
  }

  tags = merge(local.resource_tags["dlm_policy"], { Name = module.naming["dlm_policy"].full_name })

  depends_on = [aws_iam_role_policy.dlm]
}
