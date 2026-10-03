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

# Availability zones are data-derived so the CIDR maths and the AZ list can
# never drift apart.
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  availability_zones = slice(
    data.aws_availability_zones.available.names,
    0,
    var.availability_zone_count,
  )
}

module "network" {
  source = "../../../modules/network"

  # The naming module composes project-env-name, so the network resources must be
  # passed the fully prefixed stem rather than a bare "main". Without this the
  # VPC would be named "main" while 20-security names its groups dpx-<env>-*.
  name               = "${module.foundation.name_prefix}-main"
  vpc_cidr           = var.vpc_cidr
  availability_zones = local.availability_zones

  single_nat_instance = var.single_nat_instance
  nat_instance_type   = var.nat_instance_type
  compute_enabled     = var.compute_enabled

  enable_flow_logs           = var.enable_flow_logs
  flow_log_retention_days    = var.flow_log_retention_days
  enable_s3_gateway_endpoint = true

  # The endpoint policy is evaluated against the assumed-role session, which
  # matches neither the account root nor a role ARN, so it cannot name the node
  # role as principal. It is scoped to the backup buckets instead - see
  # endpoints.tf - and the node's IAM policy plus the bucket policies stay the
  # actual authorization layer. The names are derived from the same
  # <project>-<env>-* convention that 30-cluster asserts, so the two layers
  # cannot drift apart.
  s3_endpoint_allowed_bucket_names = [
    "${var.project}-${var.env}-etcd-backups",
    "${var.project}-${var.env}-postgres-backups",
  ]

  interface_endpoint_services = var.interface_endpoint_services

  tags = merge(module.foundation.standard_tags, { Tier = "network" })
}