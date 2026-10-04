# ---------------------------------------------------------------------------
# Backup storage (60-ops)
# ---------------------------------------------------------------------------
# Two objects exist per environment and they are deliberately not symmetric:
#
#   etcd      S3 bucket, created by 30-cluster (modules/cluster/etcd-backups.tf).
#             A logical `etcdctl snapshot save`, every 6h, uploaded by a systemd
#             timer on the control plane using the node role.
#   postgres  S3 bucket, created here. Landed by CloudNativePG's in-cluster
#             volume snapshots instead - see the note at the top of
#             postgres-bucket.tf for why WAL archiving to S3 is off.
#
# Plus a Data Lifecycle Manager policy over EBS snapshots, because the postgres
# backup path is volume snapshots and an untagged snapshot policy is how a
# snapshot account quietly grows without anyone noticing.
#
# Why the etcd bucket is not created here: 30-cluster is the first layer that
# needs it. The control plane's snapshot timer fires OnBootSec=15min, and an
# upload to a bucket that does not exist yet fails - the timer reports success
# anyway, because `aws s3 cp` failing inside a systemd oneshot that does not check
# the exit code is indistinguishable from a timer that has not fired yet. Moving
# the bucket later in the lifecycle would reintroduce exactly that window. So this
# module takes the name and validates it, and creates only the postgres bucket.

locals {
  name_prefix = "${var.project}-${var.env}"

  naming_resources = {
    postgres_backup_bucket = "postgres-backups"
    dlm_policy             = "dlm-policy"
    dlm_role               = "dlm-role"
  }
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
  component   = "backups"
}

locals {
  resource_tags = {
    for key, naming in module.naming : key => merge(naming.tags, var.extra_tags)
  }
}

# ---------------------------------------------------------------------------
# Cross-layer invariants
# ---------------------------------------------------------------------------
# 20-security writes the node role's S3 grants against these two names and its
# check block asserts the <project>-<env>-<kind>-backups form. Re-asserting it
# here means a rename in one layer is a plan-time failure in the other rather than
# an AccessDenied at 03:00 when the backup timer fires.

check "backup_bucket_names_match_iam" {
  assert {
    condition     = var.etcd_backup_bucket_name == format("%s-%s-etcd-backups", var.project, var.env)
    error_message = "etcd_backup_bucket_name must be <project>-<env>-etcd-backups so 20-security's node role grant still matches."
  }

  assert {
    condition     = var.postgres_backup_bucket_name == format("%s-%s-postgres-backups", var.project, var.env)
    error_message = "postgres_backup_bucket_name must be <project>-<env>-postgres-backups so 20-security's node role grant still matches."
  }

  assert {
    condition     = var.etcd_backup_bucket_name != var.postgres_backup_bucket_name
    error_message = "The etcd and postgres backup buckets must be distinct buckets."
  }
}
