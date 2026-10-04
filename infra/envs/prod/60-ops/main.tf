# Shared identity + provider wiring for this layer.
# Kept in a module so all 6 layers x 2 envs stay identical.
module "foundation" {
  source = "../../../modules/foundation"

  project           = var.project
  env               = var.env
  layer             = var.layer
  owner             = var.owner
  cost_center       = var.cost_center
  aws_region        = var.aws_region
  extra_tags        = var.extra_tags
  alb_allowed_cidrs = var.alb_allowed_cidrs
  domain_name       = var.domain_name
}

# ---------------------------------------------------------------------------
# Cross-layer lookup
# ---------------------------------------------------------------------------
# 60-ops needs three identifiers from earlier layers: the control plane, the worker
# ASG, and the ALB. They arrive as explicit variables rather than through a lookup,
# and the reasoning is worth recording because the obvious alternative does not work:
#
#   terraform_remote_state  hard-fails against a state key that has never been
#                           written ("Unable to find remote state"), and qa has no
#                           30-cluster or 40-edge at all. A layer whose entire job is
#                           to create the backup buckets qa will need on day one
#                           cannot be blocked on a cluster that does not exist yet.
#
#   data.aws_instances      returns only RUNNING instances. Verified against a
#                           stopped prod control plane in ap-south-1: the tag filter
#                           matches and the data source returns an empty list. Since
#                           this project pauses compute for cost, every discovery-by-
#                           tag approach for the cluster fails precisely when it is
#                           most useful.
#
#   data.aws_lbs            would have worked - the ALB is fully tagged (check with
#                           `aws elbv2 describe-tags`, not `describe-load-balancers`,
#                           whose Tags field comes back empty and is misleading). But
#                           the control plane and the worker ASG come from the same
#                           place, and splitting the discovery method across two
#                           layers is worse than using one predictable method for
#                           both.
#
# So the values are declared here and set in <env>.tfvars, and the checks below turn a
# missing one into a named plan failure instead of a silently absent alarm. The cost
# of this is that the values can go stale after a replacement; each variable's
# description says which layer to re-read it from, and the two AWS APIs that would
# normally answer the question are unusable here for the reasons above.

data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "${var.env}/10-network/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  network = data.terraform_remote_state.network.outputs

  # 10-network is read from remote state rather than declared, because the NAT is
  # replaced more casually than anything else in this project - see
  # docs/adr/0001-fck-nat.md - and a tfvars value would be wrong after the first
  # replacement with nothing to notice it.
  nat_instance_id = try(local.network.nat_instance_id, null)

  control_plane_instance_id = var.control_plane_instance_id
  worker_asg_name           = var.worker_asg_name
  alb_arn                   = var.alb_arn

  # Both names derived, never declared. 30-cluster owns the etcd bucket and this
  # layer only needs its name for the freshness probe; deriving it means one fewer
  # value to keep in step, and 20-security asserts the same pattern so a rename
  # breaks the plan on both sides at once.
  etcd_backup_bucket_name     = format("%s-%s-etcd-backups", var.project, var.env)
  postgres_backup_bucket_name = format("%s-%s-postgres-backups", var.project, var.env)

  backup_kms_key_arn = var.backup_kms_key_arn
}

check "targets_present" {
  assert {
    condition     = local.nat_instance_id != null
    error_message = "10-network has not published nat_instance_id. Re-apply 10-network - the output was added after it was last applied - then apply 60-ops."
  }

  # These three are only required when something depends on them. Each assertion
  # says what turns the requirement on, so turning a feature off without also
  # clearing its id is a plan failure naming the id, rather than a cluster with no
  # alarm on it.
  assert {
    condition     = !var.enable_alarms || var.control_plane_instance_id != null
    error_message = "enable_alarms = true needs control_plane_instance_id. Read it with: terraform output -no-color control_plane_instance_id  (in infra/envs/<env>/30-cluster)."
  }

  assert {
    condition     = !var.enable_alarms || var.worker_asg_name != null
    error_message = "enable_alarms = true needs worker_asg_name. Read it with: terraform output -no-color worker_asg_name  (in infra/envs/<env>/30-cluster)."
  }

  assert {
    condition     = !var.enable_alarms || var.alb_arn != null
    error_message = "enable_alarms = true needs alb_arn. Read it with: terraform output -no-color alb_arn  (in infra/envs/<env>/40-edge)."
  }

  assert {
    condition     = !var.enable_cloudwatch_agent || var.control_plane_instance_id != null
    error_message = "enable_cloudwatch_agent = true needs control_plane_instance_id - the agent is installed on the control plane over SSM."
  }

  assert {
    condition     = !var.enable_backup_probe || var.control_plane_instance_id != null
    error_message = "enable_backup_probe = true needs control_plane_instance_id - the probe runs on the control plane and publishes the snapshot-age metric."
  }
}

# ---------------------------------------------------------------------------
# Backups
# ---------------------------------------------------------------------------
module "data_backups" {
  source = "../../../modules/data-backups"

  project     = var.project
  env         = var.env
  layer       = var.layer
  owner       = var.owner
  cost_center = var.cost_center

  aws_region = var.aws_region
  extra_tags = var.extra_tags

  etcd_backup_bucket_name     = local.etcd_backup_bucket_name
  postgres_backup_bucket_name = local.postgres_backup_bucket_name

  backup_kms_key_arn = local.backup_kms_key_arn

  dlm_enabled = var.dlm_enabled

  depends_on = [module.foundation]
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------
module "observability" {
  source = "../../../modules/observability"

  project     = var.project
  env         = var.env
  layer       = var.layer
  owner       = var.owner
  cost_center = var.cost_center

  aws_region = var.aws_region
  extra_tags = var.extra_tags

  alert_email = var.alert_email

  enable_alarms       = var.enable_alarms
  enable_agent        = var.enable_cloudwatch_agent
  enable_backup_probe = var.enable_backup_probe

  control_plane_instance_id = local.control_plane_instance_id
  worker_asg_name           = local.worker_asg_name
  alb_arn                   = local.alb_arn

  etcd_backup_bucket_name = local.etcd_backup_bucket_name

  depends_on = [module.foundation]
}

# ---------------------------------------------------------------------------
# Scheduler
# ---------------------------------------------------------------------------
# Off in prod by default: Infrastructure.MD scopes scheduled stop to qa, and the
# module also refuses to create a prod schedule unless allow_prod_scheduling is set.
module "scheduler" {
  source = "../../../modules/scheduler"

  project     = var.project
  env         = var.env
  layer       = var.layer
  owner       = var.owner
  cost_center = var.cost_center

  aws_region = var.aws_region
  extra_tags = var.extra_tags

  enable_scheduling     = var.enable_scheduling
  allow_prod_scheduling = var.allow_prod_scheduling

  stop_schedule_expression  = var.stop_schedule_expression
  start_schedule_expression = var.start_schedule_expression

  # The NAT is the one instance that exists in an environment whose cluster has not
  # been applied, so it is always a target. The control plane joins it when
  # 30-cluster has been applied - and compact() dropping the null is what keeps this
  # layer plannable in qa today.
  instance_ids = compact([local.nat_instance_id, local.control_plane_instance_id])

  # qa's worker ASG rests at min 0 on its own, so there is nothing for a schedule to
  # do with it, and 30-cluster has no state to read a group name from anyway.
  worker_asg_name            = var.manage_worker_asg ? local.worker_asg_name : null
  asg_start_desired_capacity = var.asg_start_desired_capacity

  depends_on = [module.foundation]
}
