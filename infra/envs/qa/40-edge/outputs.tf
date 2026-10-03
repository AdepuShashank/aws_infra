output "layer" {
  description = "Layer name."
  value       = module.foundation.layer
}

output "env" {
  description = "Environment name."
  value       = module.foundation.env
}

output "name_prefix" {
  description = "Resource name prefix (project-env)."
  value       = module.foundation.name_prefix
}

output "standard_tags" {
  description = "Standard tag map applied to every resource in this layer."
  value       = module.foundation.standard_tags
}

output "aws_account_id" {
  description = "AWS account id resolved via STS."
  value       = module.foundation.aws_account_id
}
# ---------------------------------------------------------------------------
# Edge
# ---------------------------------------------------------------------------
output "alb_dns_name" {
  description = "Public DNS name of the ALB. This is the environment's endpoint while domain_name is null."
  value       = module.edge.alb_dns_name
}

output "alb_url" {
  description = "Base URL for the environment, including the scheme that is enabled."
  value       = module.edge.alb_url
}

output "alb_arn" {
  description = "ARN of the ALB."
  value       = module.edge.alb_arn
}

output "target_group_arn" {
  description = "Copy this into 30-cluster/prod.tfvars as alb_target_group_arns so the worker ASG registers with the ALB."
  value       = module.edge.target_group_arn
}

output "target_group_name" {
  description = "Name of the target group."
  value       = module.edge.target_group_name
}

output "https_listener_arn" {
  description = "ARN of the HTTPS listener, or null while enable_https is false."
  value       = module.edge.https_listener_arn
}

output "certificate_arn" {
  description = "Certificate presented by the HTTPS listener, or null while enable_https is false."
  value       = module.edge.certificate_arn
}

output "dns_record_fqdn" {
  description = "Fully-qualified name resolving to the ALB, or null while domain_name is null."
  value       = module.edge.dns_record_fqdn
}

output "endpoint_summary" {
  description = "How to reach the environment, and which of the three endpoint modes is active."
  value       = module.edge.endpoint_summary
}