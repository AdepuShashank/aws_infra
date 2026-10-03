locals {
  name_prefix = "${var.project}-${var.env}"

  # project-env-name[-suffix]
  full_name = join("-", compact([var.project, var.env, var.name, var.suffix]))

  tags = merge(
    {
      Name       = local.full_name
      Project    = var.project
      Env        = var.env
      Layer      = var.layer
      Owner      = var.owner
      ManagedBy  = "terraform"
      CostCenter = var.cost_center
    },
    var.component != "" ? { Component = var.component } : {},
    var.extra_tags
  )
}