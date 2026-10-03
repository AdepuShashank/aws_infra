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
# Same tag-lookup approach as 30-cluster: no second backend, no
# terraform_remote_state. The VPC comes from 10-network and the ALB security group
# from 20-security, both already applied.
#
# Consequence: this layer cannot be planned until 10-network and 20-security have
# been applied. That is intentional and the failure message says so.
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
  vpc_id = length(data.aws_vpcs.this.ids) == 1 ? data.aws_vpcs.this.ids[0] : fail(format(
    "Expected exactly one VPC tagged Project=%s Env=%s Component=network, found %d. Apply 10-network first.",
    var.project,
    var.env,
    length(data.aws_vpcs.this.ids),
  ))
}

data "aws_vpc" "this" {
  id = local.vpc_id

  depends_on = [data.aws_vpcs.this]
}

data "aws_security_group" "alb" {
  filter {
    name   = "tag:Project"
    values = [var.project]
  }

  filter {
    name   = "tag:Env"
    values = [var.env]
  }

  filter {
    name   = "tag:Component"
    values = ["security"]
  }

  filter {
    name   = "tag:Name"
    values = ["${var.project}-${var.env}-alb"]
  }
}

locals {
  # A filter that matches nothing yields no id rather than an error, and an empty
  # security group id fails deep inside CreateLoadBalancer with an opaque message.
  alb_sg_id = one(data.aws_security_group.alb[*].id) != null ? one(data.aws_security_group.alb[*].id) : fail(
    "Security group ${var.project}-${var.env}-alb not found. Apply 20-security first."
  )

  # The ALB's DNS name cannot be known before the load balancer exists, so the
  # self-signed certificate's common name is assembled from the same components
  # the provider will use: <short name>.<region>.elb.amazonaws.com.
  alb_expected_dns_name = "${local.alb_name}.${var.aws_region}.elb.amazonaws.com"
  alb_name              = substr("${var.project}-${var.env}-alb", 0, 32)
}

# ---------------------------------------------------------------------------
# Edge
# ---------------------------------------------------------------------------
module "edge" {
  source = "../../../modules/edge"

  project     = var.project
  env         = var.env
  layer       = var.layer
  owner       = var.owner
  cost_center = var.cost_center

  aws_region            = var.aws_region
  extra_tags            = var.extra_tags
  vpc_id                = local.vpc_id
  alb_security_group_id = local.alb_sg_id

  traefik_http_nodeport = var.traefik_http_nodeport

  enable_https                 = var.enable_https
  enable_redirect_to_https     = var.enable_redirect_to_https
  alb_imported_certificate_arn = var.alb_imported_certificate_arn
  domain_name                  = var.domain_name
  dns_record_name              = var.dns_record_name
  tls_policy                   = var.tls_policy

  alb_deletion_protection  = var.alb_deletion_protection
  alb_access_logs_bucket   = var.alb_access_logs_bucket
  alb_idle_timeout_seconds = var.alb_idle_timeout_seconds

  self_signed_common_name = var.self_signed_common_name != "" ? var.self_signed_common_name : local.alb_expected_dns_name

  depends_on = [module.foundation]
}

# ---------------------------------------------------------------------------
# Cross-layer contract
# ---------------------------------------------------------------------------
# 30-cluster needs this layer's target group ARN so the worker ASG registers its
# instances with the ALB. The dependency is genuinely circular - a target group
# needs instances to check, and the instances need the target group to be useful -
# so it is broken by passing the ARN through tfvars rather than by a data lookup:
#
#   1. apply 40-edge           -> read the target_group_arn output
#   2. put it in 30-cluster/prod.tfvars as alb_target_group_arns
#   3. apply 30-cluster        -> workers register with the ALB
#
# The health check tolerates the window in between: instances that are not
# registered simply are not targets yet, and the group converges on the next
# worker replacement or apply. See infra/envs/prod/40-edge/README.md.
