output "name_prefix" {
  description = "Common prefix for every resource name in this environment (project-env)."
  value       = local.name_prefix
}

output "standard_tags" {
  description = "Standard tag map applied to every taggable resource in this environment."
  value       = local.standard_tags
}

output "aws_region" {
  description = "Region this layer operates in."
  value       = var.aws_region
}

output "aws_account_id" {
  description = "AWS account id (resolved via STS, never hardcoded)."
  value       = data.aws_caller_identity.current.account_id
}

output "aws_partition" {
  description = "AWS partition derived from the caller ARN (aws, aws-us-gov, aws-cn)."
  value       = split(":", data.aws_caller_identity.current.arn)[1]
}

output "env" {
  description = "Environment name."
  value       = var.env
}

output "layer" {
  description = "Layer name."
  value       = var.layer
}

data "aws_caller_identity" "current" {}