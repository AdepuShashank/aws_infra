locals {
  ssm_path_prefix = coalesce(var.ssm_path_prefix, "/${var.project}/${var.env}/k8s")

  # Named resources, so every name comes from the naming module rather than
  # being hand-assembled at each call site.
  #
  # The map KEY is only the lookup handle (module.naming["..."]); the VALUE is
  # the name component handed to the naming module. They differ for the KMS
  # keys, where the handle is "ebs-key" but the name is "kms-ebs". Both are
  # hyphenated to satisfy the naming module's character validation.
  naming_resources = {
    alb           = "alb"
    workers       = "workers"
    control-plane = "control-plane"
    node-role     = "node-role"
    node-profile  = "node-profile"
    ebs-key       = "kms-ebs"
    ssm-key       = "kms-ssm"
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
  component   = "security"
}
