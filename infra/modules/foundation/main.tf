locals {
  name_prefix = "${var.project}-${var.env}"

  standard_tags = merge(
    {
      Project    = var.project
      Env        = var.env
      Layer      = var.layer
      Owner      = var.owner
      ManagedBy  = "terraform"
      CostCenter = var.cost_center
    },
    var.extra_tags
  )
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.standard_tags
  }

  # IMDSv2-only enforcement is an *instance* setting
  # (aws_instance / launch template metadata_options.http_tokens = "required"),
  # not a provider setting. See infra/modules/security and docs/security-baseline.md.
}