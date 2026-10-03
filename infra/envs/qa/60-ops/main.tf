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