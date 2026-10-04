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
# 10-network owns the VPC and writes its outputs to the prod/10-network state
# key. Rather than re-declaring the VPC here, the id and CIDR are resolved by
# tag lookup. The Component=network tag is what keeps this from matching a
# backup bucket, NAT instance or KMS key, all of which share the same
# Project/Env/ManagedBy trio.
#
# Consequence: `terraform plan` in this layer fails with "no matching VPC found"
# until 10-network has been applied. That is intentional -- applying this layer
# before the network exists would create security groups in the wrong VPC.
data "aws_vpcs" "this" {
  filter {
    name   = "tag:Project"
    values = [var.project]
  }

  filter {
    name   = "tag:Env"
    values = [var.env]
  }

  filter {
    name   = "tag:ManagedBy"
    values = ["terraform"]
  }

  filter {
    name   = "tag:Component"
    values = ["network"]
  }
}

locals {
  # The lookup must be unambiguous. Zero matches means 10-network has not been
  # applied; two or more means two networks carry the same tags, which would
  # silently attach security groups to the wrong VPC. fail() aborts the plan
  # with the reason rather than letting a single-element index throw an opaque
  # "list index out of range".
  #
  # aws_vpcs (plural) is what exposes the full matching id set, which is the
  # only way to detect the ambiguity. The singular aws_vpc then reads the single
  # resolved id to get attributes such as the CIDR.
  vpc_id = length(data.aws_vpcs.this.ids) == 1 ? data.aws_vpcs.this.ids[0] : fail(format(
    "Expected exactly one VPC tagged Project=%s Env=%s Component=network, found %d. Apply 10-network first, or remove the duplicate network layer.",
    var.project,
    var.env,
    length(data.aws_vpcs.this.ids),
  ))
}

data "aws_vpc" "this" {
  id = local.vpc_id

  depends_on = [data.aws_vpcs.this]
}

locals {
  vpc = data.aws_vpc.this
}

# ---------------------------------------------------------------------------
# Security layer
# ---------------------------------------------------------------------------
module "security" {
  source = "../../../modules/security"

  project     = var.project
  env         = var.env
  layer       = var.layer
  owner       = var.owner
  cost_center = var.cost_center

  vpc_id     = local.vpc_id
  vpc_cidr   = local.vpc.cidr_block
  aws_region = var.aws_region

  allowed_cidrs = var.alb_allowed_cidrs
  nodeports     = var.traefik_nodeports

  ssm_path_prefix = var.ssm_path_prefix

  etcd_backup_bucket_name     = var.etcd_backup_bucket_name
  postgres_backup_bucket_name = var.postgres_backup_bucket_name

  kms_deletion_window_in_days = var.kms_deletion_window_in_days
}

# The bucket names are owned here because they must match the object ARNs the
# node role is granted in 20-security. 60-ops derives the same names with
# this suffix stripped, so the two layers cannot drift apart.
check "backup_bucket_names" {
  assert {
    condition     = var.etcd_backup_bucket_name == format("%s-%s-etcd-backups", var.project, var.env)
    error_message = "etcd_backup_bucket_name must be <project>-<env>-etcd-backups so 60-ops can derive it."
  }

  assert {
    condition     = var.postgres_backup_bucket_name == format("%s-%s-postgres-backups", var.project, var.env)
    error_message = "postgres_backup_bucket_name must be <project>-<env>-postgres-backups so 60-ops can derive it."
  }
}