locals {
  name_prefix = "${var.project}-${var.env}"

  standard_tags = merge(
    {
      Name       = local.name_prefix
      Project    = var.project
      Env        = var.env
      Layer      = "00-bootstrap"
      Owner      = var.owner
      ManagedBy  = "terraform"
      CostCenter = var.cost_center
    },
    var.extra_tags
  )

  state_bucket_name = coalesce(var.state_bucket_name, "${var.project}-tfstate-${var.env}")
  kms_alias_name    = "alias/${local.name_prefix}-tfstate"
  alerts_topic_name = "${local.name_prefix}-alerts"

  # GitHub OIDC "sub" claim values that are allowed to assume a role.
  github_repo_prefix = "repo:${var.github_repository_owner}/${var.github_repository_name}"
  github_subjects = concat(
    [for b in var.github_allowed_branches : "${local.github_repo_prefix}:ref:refs/heads/${b}"],
    [for e in var.github_allowed_environments : "${local.github_repo_prefix}:environment:${e}"],
  )

  github_repo_is_placeholder = (
    var.github_repository_owner == "REPLACE_ME" || var.github_repository_name == "REPLACE_ME"
  )
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.standard_tags
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}